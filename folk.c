#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>
#include <stdatomic.h>
#include <inttypes.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/syscall.h>
#include <fcntl.h>

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include <jim.h>

#define STB_DS_IMPLEMENTATION
#include "vendor/stb_ds.h"

#include "vendor/c11-queues/mpmc_queue.h"

#include "epoch.h"
#include "db.h"
#include "common.h"
#include "sysmon.h"
#include "output-redirection.h"

#define FATAL(...) do { dprintf(realStderr, __VA_ARGS__); exit(1); } while(0)

#include "block-stats.h"

ThreadControlBlock threads[THREADS_MAX];
int _Atomic threadCount;
__thread ThreadControlBlock* self;
// helper function to get self from LLDB:
ThreadControlBlock* getSelf() { return self; }

struct mpmc_queue globalWorkQueue;
_Atomic int globalWorkQueueSize;
void globalWorkQueueInit() {
    mpmc_queue_init(&globalWorkQueue, 16384, &memtype_heap);
    globalWorkQueueSize = 0;
}
void traceItem(char* buf, size_t bufsz, WorkQueueItem item);
void globalWorkQueuePush(WorkQueueItem item) {
    WorkQueueItem* pushee = malloc(sizeof(item));
    *pushee = item;
    if (!mpmc_queue_push(&globalWorkQueue, pushee)) {
        while (mpmc_queue_available(&globalWorkQueue)) {
            WorkQueueItem* x;
            mpmc_queue_pull(&globalWorkQueue, (void **)&x);
            char s[1000]; traceItem(s, 1000, *x);
            dprintf(realStderr, "(%.200s)\n", s);
        }
        FATAL("globalWorkQueuePush: failed\n");
    }
    globalWorkQueueSize++;
}
WorkQueueItem globalWorkQueueTake() {
    WorkQueueItem ret = { .op = NONE };
    if (globalWorkQueueSize > 0) {
        WorkQueueItem* pullee;
        if (mpmc_queue_pull(&globalWorkQueue, (void **)&pullee)) {
            globalWorkQueueSize--;
            ret = *pullee;
            free(pullee);
        }
    }
    return ret;
}

void appropriateWorkQueuePush(WorkQueueItem item) {
    if (self) {
        workQueuePush(self->workQueue, item);
        return;
    }
    globalWorkQueuePush(item);
}

// These are used by dynamically-loaded Tcl-C modules, especially for
// error handling.
__thread Jim_Interp* interp = NULL;
__thread jmp_buf __onError;
// __onError can only be set once for one call into C; if it's already
// set and you try to set it again (maybe because you called a _Cmd
// wrapper directly), you shouldn't.
__thread bool __onErrorIsSet;

Db* db;

// Appends a string to a list. List be non-shared
static void jimAppendString(Jim_Interp* interp, Jim_Obj* listPtr, const char* str) {
    Jim_ListAppendElement(interp, listPtr, Jim_NewStringObj(interp, str, -1));
}

static void destructorHelper(void* arg) {
    // This dispatches an evaluation task to the global queue, so that
    // this function can be invoked from sysmon (which doesn't have
    // its own Tcl interpreter & work queue).

    char* code = (char*) arg;

    globalWorkQueuePush((WorkQueueItem) {
            .op = EVAL,
            .eval = { .code = code }
        });
}

typedef struct EnvironmentBinding {
    char name[100];
    Jim_Obj* value;
} EnvironmentBinding;
typedef struct Environment {
    int nBindings;
    EnvironmentBinding bindings[];
} Environment;

// This function lives in folk.c and not trie.c (where most
// Clause/matching logic lives) because it operates at the Tcl level,
// building up a mapping of strings to Tcl objects. Caller must free
// the returned Environment*.
// "a" and "b" must have a list internal representation.
Environment* clauseUnify(Jim_Interp* interp, Jim_Obj* a, Jim_Obj* b) {
    assert(Jim_IsList(a));
    assert(Jim_IsList(b));

    int aLen = a->internalRep.listValue.len;
    int bLen = b->internalRep.listValue.len;

    Jim_Obj** aTerms = a->internalRep.listValue.ele;
    Jim_Obj** bTerms = b->internalRep.listValue.ele;

    Environment* env = malloc(sizeof(Environment) + sizeof(EnvironmentBinding)*aLen);
    env->nBindings = 0;

    for (int i = 0; i < aLen && i < bLen; i++) {
        char aVarName[100] = {0}; char bVarName[100] = {0};
        if (trieScanVariable(Jim_GetString(interp, aTerms[i], NULL), aVarName, sizeof(aVarName))) {
            if (aVarName[0] == '.' && aVarName[1] == '.' && aVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName + 3, sizeof(binding->name) - 3);
                binding->value = Jim_NewListObj(interp, bTerms + i, bLen - i);
            } else if (!trieVariableNameIsNonCapturing(aVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = bTerms[i];
            }
        } else if (trieScanVariable(Jim_GetString(interp, bTerms[i], NULL), bVarName, sizeof(bVarName))) {
            if (bVarName[0] == '.' && bVarName[1] == '.' && bVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName + 3, sizeof(binding->name) - 3);
                binding->value = Jim_NewListObj(interp, aTerms + i, aLen - i);
            } else if (!trieVariableNameIsNonCapturing(bVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = aTerms[i];
            }
        } else if (!Jim_StringEqObj(interp, aTerms[i], bTerms[i])) {
            free(env);
            fprintf(stderr, "clauseUnify: Unification of (%s) (%s) failed\n",
                    Jim_String(interp, a), Jim_String(interp, b));
            return NULL;
        }
    }
    return env;
}

// Assert! the time is 3
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_Obj* clause = Jim_NewListObj(interp, argv + 1, argc - 1);

    Jim_Obj* scriptObj = interp->evalFrame->scriptObj;
    const char* sourceFileName;
    int sourceLineNumber;
    if (Jim_ScriptGetSourceFileName(interp, scriptObj, &sourceFileName) != JIM_OK) {
        sourceFileName = "<unknown>";
    }
    if (Jim_ScriptGetSourceLineNumber(interp, scriptObj, &sourceLineNumber) != JIM_OK) {
        sourceLineNumber = -1;
    }

    Jim_MakeImmutable(interp, clause);
    Jim_IncrRefCount(clause);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = ASSERT,
       .assert = {
           .clause = clause,
           .sourceFileName = strdup(sourceFileName),
           .sourceLineNumber = sourceLineNumber,
       }
    });

    return (JIM_OK);
}
// Retract! the time is /t/
static int RetractFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_Obj* pattern = Jim_NewListObj(interp, argv + 1, argc - 1);

    Jim_MakeImmutable(interp, pattern);
    Jim_IncrRefCount(pattern);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RETRACT,
       .retract = { .pattern = pattern }
    });

    return (JIM_OK);
}

static void reactToNewStatement(StatementRef ref);

int64_t _Atomic latestVersion = 0; // TODO: split by key?
// Note: returns an acquired statement that the caller should release.
Statement* HoldStatementGloballyAcquiring(const char *key, double version,
                                          Jim_Obj *clause, long keepMs, const char *destructorCode,
                                          const char *sourceFileName, int sourceLineNumber) {
/* #ifdef TRACY_ENABLE */
/*     char *s = clauseToString(clause); */
/*     TracyCMessageFmt("hold: %.200s", s); free(s); */
/* #endif */

    StatementRef oldRef; Statement* newStmt;

    newStmt = dbHoldStatement(db, interp, key, version,
                              clause, keepMs,
                              sourceFileName, sourceLineNumber,
                              &oldRef);

    Destructor* destructor = NULL;
    if (destructorCode != NULL) {
        destructor = destructorNew(destructorHelper, strdup(destructorCode));
    }

    if (newStmt != NULL) {
        if (destructor != NULL) {
            statementAddDestructor(newStmt, destructor);
        }

        StatementRef newRef = statementRef(db, newStmt);
        reactToNewStatement(newRef);
    } else {
        if (destructor != NULL) {
            destructorRun(destructor);
            free(destructor);
        }
    }

    if (!statementRefIsNull(oldRef)) {
        Statement* stmt;
        if ((stmt = statementAcquire(db, oldRef))) {
            statementDecrParentCountAndMaybeRemoveSelf(db, stmt);
            statementRelease(db, stmt);
        }
    }

    return newStmt;
}
void HoldStatementGlobally(const char *key, double version,
                           Jim_Obj *clause, long keepMs, const char *destructorCode,
                           const char *sourceFileName, int sourceLineNumber) {
    Statement* stmt = HoldStatementGloballyAcquiring(key, version,
                                                     clause, keepMs, destructorCode,
                                                     sourceFileName, sourceLineNumber);
    if (stmt != NULL) {
        dbInflightDecr(db, stmt);
        statementRelease(db, stmt);
    }
}
static int HoldStatementGloballyFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 8);

    const char* sourceFileName;
    long sourceLineNumber;
    sourceFileName = Jim_String(interp, argv[6]);
    if (sourceFileName == NULL) { return JIM_ERR; }
    if (Jim_GetLong(interp, argv[7], &sourceLineNumber) == JIM_ERR) {
        return JIM_ERR;
    }

    const char *key = Jim_String(interp, argv[1]);
    double version; Jim_GetDouble(interp, argv[2], &version);
    Jim_Obj *clause = argv[3];
    long keepMs; Jim_GetLong(interp, argv[4], &keepMs);
    int destructorCodeLen;
    const char* destructorCode = Jim_GetString(interp, argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    HoldStatementGlobally(key, version,
                          clause, keepMs, destructorCode,
                          sourceFileName, sourceLineNumber);

    return (JIM_OK);
}


static StatementRef Say(Jim_Obj* clause, long keepMs,
                        AtomicallyVersion* atomicallyVersion,
                        const char *destructorCode,
                        const char *sourceFileName, int sourceLineNumber) {
    MatchRef parent;
    if (self->currentMatch) {
        parent = matchRef(db, self->currentMatch);

    } else {
        parent = MATCH_REF_NULL;
        const char *s = Jim_String(interp, clause);
        fprintf(stderr, "Warning: Creating unparented Say (%.100s)\n", s);
    }

    Statement* stmt;
    stmt = dbInsertOrReuseStatement(db, interp, clause, keepMs,
                                    atomicallyVersion,
                                    sourceFileName, sourceLineNumber,
                                    parent, NULL);

    Destructor* destructor = NULL;
    if (destructorCode != NULL) {
        destructor = destructorNew(destructorHelper, strdup(destructorCode));
    }

    if (stmt != NULL) {
        if (destructor != NULL) {
            statementAddDestructor(stmt, destructor);
        }

        StatementRef ref = statementRef(db, stmt);

        reactToNewStatement(ref);

        dbInflightDecr(db, stmt);
        statementRelease(db, stmt);
        return ref;

    } else {
        if (destructor != NULL) {
            destructorRun(destructor);
            free(destructor);
        }
        return STATEMENT_REF_NULL;
    }
}

static int SayWithSourceFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc >= 7);
    Jim_Obj* clause = Jim_NewListObj(interp, argv + 6, argc - 6);

    const char* sourceFileName;
    long sourceLineNumber;
    sourceFileName = Jim_String(interp, argv[1]);
    if (sourceFileName == NULL) { return JIM_ERR; }

    if (Jim_GetLong(interp, argv[2], &sourceLineNumber) == JIM_ERR) {
        goto err;
    }

    long keepMs;
    if (Jim_GetLong(interp, argv[3], &keepMs) == JIM_ERR) {
        goto err;
    }

    AtomicallyVersion* atomicallyVersion = NULL;
    const char* atomicallyVersionStr = Jim_String(interp, argv[4]);
    if (atomicallyVersionStr && strlen(atomicallyVersionStr) > 0) {
        sscanf(atomicallyVersionStr, "(AtomicallyVersion*) %p", &atomicallyVersion);
    }

    int destructorCodeLen;
    const char* destructorCode = Jim_GetString(interp, argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    if (self->inSubscription) {
        Jim_SetResultString(interp, "Cannot call Say within Subscribe", -1);
        goto err;
    }

    Say(clause, keepMs,
        atomicallyVersion, destructorCode,
        sourceFileName, (int) sourceLineNumber);
    return JIM_OK;

 err:
    return JIM_ERR;
}

static int DestructorFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    if (self->inSubscription) {
        Jim_SetResultString(interp, "Cannot create destructor in a subscribe block", -1);
        return JIM_ERR;
    }

    Destructor* d = destructorNew(destructorHelper,
                                  strdup(Jim_String(interp, argv[1])));
    matchAddDestructor(self->currentMatch, d);
    return JIM_OK;
}

static void Notify(Jim_Obj* toNotify);
static int NotifyFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc >= 2);

    Notify(Jim_NewListObj(interp, argv + 1, argc - 1));
    return JIM_OK;
}

extern int statementParentCount(Statement* stmt);
Jim_Obj* QuerySimple(bool isAtomically, Jim_Obj* pattern) {
    // pattern can be on the temp list, as its child elements
    // can outlast the temp list being cleared
    pattern = Jim_DupIfImmutAndWrongRep(interp, pattern, Jim_ListType(), JIM_TEMP_LIST);
    // make sure it has a list rep
    Jim_ListLength(interp, pattern);

    ResultSet* rs = dbQuery(db, pattern);

    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);
    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* result = statementAcquire(db, rs->results[i]);
        if (result == NULL) { continue; }

        // If `isAtomically` is on, then throw away any
        // statement that has an AtomicallyVersion _and_ that
        // AtomicallyVersion isn't converged yet.
        if (isAtomically &&
            statementAtomicallyVersion(result) != NULL &&
            !dbAtomicallyVersionHasConverged(statementAtomicallyVersion(result))) {

            /* fprintf(stderr, "DISCARD %.100s\n", */
            /*         clauseToString(statementClause(result))); */
            statementRelease(db, result);
            continue;
        }

        Environment* env = clauseUnify(interp, pattern, statementClause(result));
        if (env == NULL) {
            statementRelease(db, result);
            continue;
        }

        Jim_Obj* envDict[(env->nBindings + 1) * 2];
        envDict[0] = Jim_NewStringObj(interp, "__ref", -1);
        char buf[100]; snprintf(buf, 100,  "s%d:%d", rs->results[i].idx, rs->results[i].gen);
        envDict[1] = Jim_NewStringObj(interp, buf, -1);

        for (int j = 0; j < env->nBindings; j++) {
            envDict[(j+1)*2] = Jim_NewStringObj(interp, env->bindings[j].name, -1);
            envDict[(j+1)*2+1] = env->bindings[j].value;
        }

        Jim_Obj *resultObj = Jim_NewDictObj(interp, envDict, (env->nBindings + 1) * 2);
        Jim_ListAppendElement(interp, ret, resultObj);

        statementRelease(db, result);
        free(env);
    }

    free(rs);
    return ret;
}

static int QuerySimpleFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc >= 3);

    int isAtomically;
    if (Jim_GetBoolean(interp, argv[1], &isAtomically) != JIM_OK) {
        return JIM_ERR;
    }

    Jim_Obj* pattern = Jim_NewListObj(interp, argv + 2, argc - 2);

    Jim_Obj *retObj = QuerySimple(isAtomically, pattern);
    Jim_FreeNewObj(pattern);
    
    Jim_SetResult(interp, retObj);
    return JIM_OK;
}

static int StatementAcquireFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);

    StatementRef ref;
    assert(sscanf(Jim_String(interp, argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);

    if (statementAcquire(db, ref) == NULL) {
        Jim_SetResultString(interp, "Unable to acquire statement.", -1);
        return JIM_ERR;
    }
    return JIM_OK;
}
static int StatementReleaseFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);

    StatementRef ref;
    assert(sscanf(Jim_String(interp, argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);

    statementRelease(db, statementUnsafeGet(db, ref));
    return JIM_OK;
}
static int __statementOfCurrentMatchSourceInfoFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    StatementRef stmtRef = STATEMENT_REF_NULL;
    mutexLock(&self->currentItemMutex);
    if (self->currentItem.op == RUN_WHEN) {
        stmtRef = self->currentItem.runWhen.stmt;
    }
    mutexUnlock(&self->currentItemMutex);

    if (statementRefIsNull(stmtRef)) {
        Jim_SetEmptyResult(interp);
        return JIM_OK;
    }

    Statement* stmt = statementAcquire(db, stmtRef);
    if (stmt == NULL) {
        Jim_SetEmptyResult(interp);
        return JIM_OK;
    }

    const char* fileName = statementSourceFileName(stmt);
    int lineNumber = statementSourceLineNumber(stmt);
    Jim_Obj* result[2] = {
        Jim_NewStringObj(interp, fileName ? fileName : "", -1),
        Jim_NewIntObj(interp, lineNumber),
    };
    Jim_SetResult(interp, Jim_NewListObj(interp, result, 2));

    statementRelease(db, stmt);
    return JIM_OK;
}

static int __scanVariableFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    char varName[100];
    if (trieScanVariable(Jim_String(interp, argv[1]), varName, 100)) {
        Jim_SetResultString(interp, varName, strlen(varName));
    } else {
        Jim_SetResultBool(interp, false);
    }
    return JIM_OK;
}
static int __variableNameIsNonCapturingFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    Jim_SetResultBool(interp, trieVariableNameIsNonCapturing(Jim_String(interp, argv[1])));
    return JIM_OK;
}
static int __startsWithDollarSignFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    Jim_SetResultBool(interp, Jim_String(interp, argv[1])[0] == '$');
    return JIM_OK;
}
static int __currentMatchRefFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    if (self->currentMatch == NULL) {
        Jim_SetEmptyResult(interp);
        return JIM_OK;
    }

    MatchRef ref = matchRef(db, self->currentMatch);
    char ret[100]; snprintf(ret, 100, "m%u:%u", ref.idx, ref.gen);
    Jim_SetResultString(interp, ret, strlen(ret));
    return JIM_OK;
}
static int __statementIncompleteChildMatchesCountFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    StatementRef ref;
    assert(sscanf(Jim_String(interp, argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);
    Statement* stmt = statementAcquire(db, ref);
    if (stmt == NULL) {
        Jim_SetResultInt(interp, 0);
        return JIM_OK;
    }
    Jim_SetResultInt(interp, statementIncompleteChildMatchesCount(db, stmt));
    statementRelease(db, stmt);
    return JIM_OK;
}
static int __whenOfCurrentMatchIncompleteChildMatchesCountFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    StatementRef whenRef = STATEMENT_REF_NULL;
    mutexLock(&self->currentItemMutex);
    if (self->currentItem.op == RUN_WHEN) {
        whenRef = self->currentItem.runWhen.when;
    }
    mutexUnlock(&self->currentItemMutex);

    if (statementRefIsNull(whenRef)) { return JIM_ERR; }

    Statement* when = statementAcquire(db, whenRef);
    if (when == NULL) {
        // This shouldn't happen?
        Jim_SetResultBool(interp, false);
        return JIM_OK;
    }

    Jim_SetResultInt(interp, statementIncompleteChildMatchesCount(db, when));

    statementRelease(db, when);
    return JIM_OK;
}
static int __isInSubscriptionFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_SetResultBool(interp, self->inSubscription);
    return JIM_OK;
}
static int __isTracyEnabledFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
#ifdef TRACY_ENABLE
    Jim_SetResultBool(interp, true);
#else
    Jim_SetResultBool(interp, false);
#endif
    return JIM_OK;
}
static int __dbFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    char ret[100]; snprintf(ret, 100, "(Db*) %p", db);
    Jim_SetResultString(interp, ret, strlen(ret));
    return JIM_OK;
}
static int __threadIdFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_SetResultInt(interp, self->index);
    return JIM_OK;
}

static int __setFreshAtomicallyVersionOnKeyFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    const char* key = Jim_String(interp, argv[1]);
    self->currentAtomicallyVersion =
        dbFreshAtomicallyVersionOnKey(db, key,
                                      matchRef(db, self->currentMatch));
    matchSetAtomicallyVersion(self->currentMatch, self->currentAtomicallyVersion);
    return JIM_OK;
}
static int __currentAtomicallyVersionFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    if (self->currentAtomicallyVersion == NULL) {
        Jim_SetResultString(interp, "", -1);
    } else {
        char ret[100];
        snprintf(ret, 100, "(AtomicallyVersion*) %p",
                 self->currentAtomicallyVersion);
        Jim_SetResultString(interp, ret, strlen(ret));
    }
    return JIM_OK;
}

static int setpgrpFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    int ret = setpgrp();
    if (ret != -1) {
        return JIM_OK;
    } else {
        Jim_SetResultString(interp, strerror(errno), -1);
        return JIM_ERR;
    }
}
static int exitFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    long exitCode; Jim_GetLong(interp, argv[1], &exitCode);

    // Use _exit to skip atexit handlers and avoid crashing threads
    // that are in non-cancellation-safe code (like dlopen).
    // Ignore SIGTRAP so pthread_cancel doesn't cause EXC_BREAKPOINT.
    fflush(stdout);
    fflush(stderr);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    signal(SIGTRAP, SIG_IGN);
    _exit(exitCode);

    return JIM_OK;
}

void initSysmonInterp() {
    interp = Jim_CreateInterp();
}

void rewindSysmonInterp() {
    Jim_RewindTempList(interp);
}

static void interpBoot() {
    interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    outputRedirectionInterpSetup(interp);

    Jim_CreateCommand(interp, "Assert!", AssertFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Retract!", RetractFunc, NULL, NULL);
    Jim_CreateCommand(interp, "HoldStatementGlobally!", HoldStatementGloballyFunc, NULL, NULL);

    Jim_CreateCommand(interp, "NotifyImpl", NotifyFunc, NULL, NULL);

    Jim_CreateCommand(interp, "SayWithSource", SayWithSourceFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Destructor", DestructorFunc, NULL, NULL);

    Jim_CreateCommand(interp, "QuerySimple!", QuerySimpleFunc, NULL, NULL);

    Jim_CreateCommand(interp, "StatementAcquire!", StatementAcquireFunc, NULL, NULL);
    Jim_CreateCommand(interp, "StatementRelease!", StatementReleaseFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__statementOfCurrentMatchSourceInfo", __statementOfCurrentMatchSourceInfoFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__scanVariable", __scanVariableFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__currentMatchRef", __currentMatchRefFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__statementIncompleteChildMatchesCount", __statementIncompleteChildMatchesCountFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__whenOfCurrentMatchIncompleteChildMatchesCount", __whenOfCurrentMatchIncompleteChildMatchesCountFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__isInSubscription", __isInSubscriptionFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__isTracyEnabled", __isTracyEnabledFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__blockRuntimeStats", __blockRuntimeStatsFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__db", __dbFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__threadId", __threadIdFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__setFreshAtomicallyVersionOnKey", __setFreshAtomicallyVersionOnKeyFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__currentAtomicallyVersion", __currentAtomicallyVersionFunc, NULL, NULL);

    Jim_CreateCommand(interp, "setpgrp", setpgrpFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Exit!", exitFunc, NULL, NULL);

    if (Jim_EvalFile(interp, "prelude.tcl") == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        FATAL("prelude: %s\n", Jim_String(interp, Jim_GetResult(interp)));
    }
}
void eval(const char* code) {
    if (interp == NULL) { interpBoot(); }

    int error = Jim_Eval(interp, code);
    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "eval: (%s) -> (%s)\n", code, Jim_String(interp, Jim_GetResult(interp)));
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);
    }
}

//////////////////////////////////////////////////////////
// Evaluator
//////////////////////////////////////////////////////////

void workerExit();

// Caller is responsible for ref counting all provided objects
static int runBlock(Jim_Obj* bodyPattern, Jim_Obj* toUnifyWith, Jim_Obj* bodyObj,
                    const char *sourceFileName, int sourceLineNumber,
                    Jim_Obj *envStackObj) {
    Jim_Obj* combinedEnvStack = Jim_NewListObj(interp, NULL, 0);
    Jim_IncrRefCount(combinedEnvStack);

    // Set the source info for the bodyObj:
    const char *unusedPtr;
    if (Jim_ScriptGetSourceFileName(interp, bodyObj, &unusedPtr) == JIM_ERR) {
        // apparently Jim_SetSourceInfo is happy to not check whether the object 
        // has a usable string before setting it to a source value
        Jim_String(interp, bodyObj);

        assert(!Jim_IsShared(bodyObj));

        // HACK: We only set the source info if it's not already
        // there, because setting the source info destroys the
        // internal script representation and forces the code to be
        // reparsed (why??).
        Jim_SetSourceInfo(interp, bodyObj,
                          Jim_NewStringObj(interp, sourceFileName, -1),
                          sourceLineNumber, 0);
    }

    {
        // Figure out all the bound match variables by unifying when &
        // stmt:
        Environment* env = clauseUnify(interp, bodyPattern, toUnifyWith);
        if (env == NULL) {
            // Unification failed.
            Jim_DecrRefCount(bodyObj);
            return JIM_OK;
        }

        if (env->nBindings > 50) {
            fprintf(stderr, "runBlock: Too many bindings in env: %d\n",
                    env->nBindings);
            Jim_DecrRefCount(bodyObj);
            free(env);
            return JIM_ERR;
        }

        Jim_Obj *objs[env->nBindings*2];
        for (int i = 0; i < env->nBindings; i++) {
            objs[i*2] = Jim_NewStringObj(interp, env->bindings[i].name, -1);
            objs[i*2 + 1] = env->bindings[i].value;
        }

        Jim_Obj* boundEnvObj = Jim_NewDictObj(interp, objs, env->nBindings*2);

        Jim_ListAppendList(interp, combinedEnvStack, envStackObj);
        Jim_ListAppendElement(interp, combinedEnvStack, boundEnvObj);

        free(env);
    }

    // Rule: you should never be holding a lock while doing a Tcl
    // evaluation.
    interp->signal_level++;
    int error;
    {
#ifdef TRACY_ENABLE
        char name[1000];
        int namesz = snprintf(name, 1000, "%s:%d",
                              sourceFileName, sourceLineNumber);
        uint64_t srcloc = ___tracy_alloc_srcloc(sourceLineNumber,
                                               sourceFileName, strlen(sourceFileName),
                                               name, namesz,
                                               0);
        TracyCZoneCtx ctx = ___tracy_emit_zone_begin_alloc(srcloc, 1);
#endif

        Jim_Obj *objv[] = {
            // TODO: pool this string?
            Jim_NewStringObj(interp, "evaluateBlock", -1),
            bodyObj,
            combinedEnvStack
        };
        int64_t t0 = timestamp_get(CLOCK_MONOTONIC);
        error = Jim_EvalObjVector(interp, sizeof(objv)/sizeof(objv[0]), objv);
        blockStatsUpdate(sourceFileName, sourceLineNumber,
                         timestamp_get(CLOCK_MONOTONIC) - t0);

#ifdef TRACY_ENABLE
        ___tracy_emit_zone_end(ctx);
#endif
    }
    interp->signal_level--;

    Jim_DecrRefCount(combinedEnvStack);
    return error;
}

static void runWhenBlock(StatementRef whenRef, Jim_Obj* whenPattern, StatementRef stmtRef) {
    // Dereference refs. if any fail, then skip this work item.
    // Exception: stmtRef can be a null ref if and only if whenPattern
    // is {}.
    Statement* when = NULL;
    Statement* stmt = NULL;
    when = statementAcquire(db, whenRef);
    if (when == NULL) return;

    if (!statementRefIsNull(stmtRef)) {
        stmt = statementAcquire(db, stmtRef);
        if (stmt == NULL) {
            statementRelease(db, when);
            return;
        }
    }
    // Note that we have acquired `when` and `stmt` at this point, and
    // we hold them until Tcl evaluation terminates.

    // Now when is definitely non-null and stmt is non-null if
    // applicable.

    // parent this match
    if (stmt != NULL) {
        StatementRef parents[] = { whenRef, stmtRef };

        AtomicallyVersion* whenAtomicallyVersion = statementAtomicallyVersion(when);
        AtomicallyVersion* stmtAtomicallyVersion = statementAtomicallyVersion(stmt);
        AtomicallyVersion* atomicallyVersion = NULL;
        if (whenAtomicallyVersion && stmtAtomicallyVersion &&
            whenAtomicallyVersion != stmtAtomicallyVersion) {
            fprintf(stderr, "runWhenBlock: Warning: Conflicting atomicallyVersion between:\n"
                    "  when (%p): (%.150s)\n"
                    "  stmt (%p): (%.150s)\n",
                    whenAtomicallyVersion, Jim_String(interp, statementClause(when)),
                    stmtAtomicallyVersion, Jim_String(interp, statementClause(stmt)));
        }
        atomicallyVersion = stmtAtomicallyVersion ?
            stmtAtomicallyVersion : whenAtomicallyVersion;
        self->currentMatch = dbInsertMatch(db, 2, parents,
                                           atomicallyVersion,
                                           self->index);
        self->currentAtomicallyVersion = atomicallyVersion;
    } else {
        StatementRef parents[] = { whenRef };
        self->currentMatch = dbInsertMatch(db, 1, parents,
                                           statementAtomicallyVersion(when),
                                           self->index);
        self->currentAtomicallyVersion = statementAtomicallyVersion(when);
    }
    if (self->currentAtomicallyVersion != NULL) {
        dbAtomicallyVersionInflightIncr(self->currentAtomicallyVersion);
    }
    // We don't want to hang onto these inflight when running the
    // block. (If we're keeping one, we've just incr-ed it for
    // ourselves before this.)
    dbInflightDecr(db, when);
    dbInflightDecr(db, stmt);

    // check if match failed to be created
    if (!self->currentMatch) {
        // A parent is gone. Abort.
        if (self->currentAtomicallyVersion != NULL) {
            dbAtomicallyVersionInflightDecr(db, self->currentAtomicallyVersion);
        }

        statementRelease(db, when);
        if (stmt != NULL) {
            statementRelease(db, stmt);
        }
        return;
    }

    // make sure this is initialized
    self->inSubscription = false;

    // now that all the preconditions are met, we can get the parameters set
    // up for `runBlock`
    Jim_Obj* whenClause = statementClause(when);
    Jim_Obj* stmtClause = stmt == NULL ? whenPattern : statementClause(stmt);

    assert(Jim_IsList(whenClause));
    assert(Jim_ListLength(interp, whenClause) >= 5);

    Jim_Obj** whenClauseTerms = whenClause->internalRep.listValue.ele;
    size_t whenClauseLen = whenClause->internalRep.listValue.len;

    // when the time is /t/ /body/ with environment /capturedEnvStack/
    Jim_Obj* bodyObj = Jim_DuplicateObj(interp, whenClauseTerms[whenClauseLen - 4], JIM_LIVE_LIST);
    Jim_Obj* capturedEnvStack = whenClauseTerms[whenClauseLen - 1];

    Jim_IncrRefCount(stmtClause);
    Jim_IncrRefCount(bodyObj);
    Jim_IncrRefCount(capturedEnvStack);

    runBlock(whenPattern, stmtClause, bodyObj,
        statementSourceFileName(when), statementSourceLineNumber(when), capturedEnvStack);

    if (self->currentAtomicallyVersion != NULL) {
        dbAtomicallyVersionInflightDecr(db, self->currentAtomicallyVersion);
    }

    statementRelease(db, when);
    if (stmt != NULL) { statementRelease(db, stmt); }

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;

    Jim_DecrRefCount(stmtClause);
    Jim_DecrRefCount(bodyObj);
    Jim_DecrRefCount(capturedEnvStack);
}

// Caller is responsible for freeing passed in clauses
static void runSubscribeBlock(StatementRef subscribeRef, Jim_Obj* subscribePattern,
                              Jim_Obj* notifyClause) {
    Statement* subscribeStmt = statementAcquire(db, subscribeRef);
    if (subscribeStmt == NULL) {  return; }

    self->currentMatch = NULL;
    self->inSubscription = true;

    Jim_Obj* subscribeClause = statementClause(subscribeStmt);
    assert(Jim_IsList(subscribeClause));
    assert(Jim_ListLength(interp, subscribeClause) >= 5);

    Jim_Obj** subscribeClauseTerms = subscribeClause->internalRep.listValue.ele;
    size_t subscribeClauseLen = subscribeClause->internalRep.listValue.len;

    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /capturedEnvStack/
    Jim_Obj* bodyObj = Jim_DuplicateObj(interp, subscribeClauseTerms[subscribeClauseLen - 4], JIM_LIVE_LIST);
    Jim_Obj* capturedEnvStack = subscribeClauseTerms[subscribeClauseLen - 1];

    Jim_IncrRefCount(bodyObj);
    Jim_IncrRefCount(capturedEnvStack);

    runBlock(subscribePattern, notifyClause, bodyObj,
        statementSourceFileName(subscribeStmt),
        statementSourceLineNumber(subscribeStmt),
        capturedEnvStack);

    self->inSubscription = false;
    statementRelease(db, subscribeStmt);

    Jim_DecrRefCount(capturedEnvStack);
    Jim_DecrRefCount(bodyObj);
}

// Copies the whenPattern Clause and all terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunWhenBlock(StatementRef whenRef, Jim_Obj* whenPattern, StatementRef stmtRef) {
    // make sure whenPattern is immutable, as it's about to become shared
    Jim_MakeImmutable(interp, whenPattern);
    Jim_IncrRefCount(whenPattern);

    // TODO: Ideally we wouldn't re-acquire.
    Statement* stmt = statementAcquire(db, whenRef);
    Statement* when = statementAcquire(db, stmtRef);
    if (stmt != NULL) {
        dbInflightIncr(stmt);
        statementRelease(db, stmt);
    }
    if (when != NULL) {
        dbInflightIncr(when);
        statementRelease(db, when);
    }
    
    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RUN_WHEN,
       .runWhen = { .when = whenRef, .whenPattern = whenPattern, .stmt = stmtRef }
    });
}

// Copies the clauses and all their terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunSubscriptionBlock(StatementRef subscribeRef, Jim_Obj* subscribePattern,
                              Jim_Obj* notifyClause) {
    Jim_MakeImmutable(interp, subscribePattern);
    Jim_MakeImmutable(interp, notifyClause);
    Jim_IncrRefCount(subscribePattern);
    Jim_IncrRefCount(notifyClause);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RUN_SUBSCRIBE,
       .runSubscribe = {
            .subscribeRef = subscribeRef,
            .subscribePattern = subscribePattern,
            .notifyClause = notifyClause
        }
    });
}

#define TERM_STATIC(str) ({ \
    static struct { int32_t len; char buf[sizeof(str)]; } _term = { \
        .len = sizeof(str) - 1, .buf = str \
    }; \
    (Term*)&_term; \
})

// Prepends `/someone/ claims` to `clause`. Returns NULL if `clause`
// shouldn't be claimized. Returns new Jim_Obj with refCount = 0
Jim_Obj* claimizeClause(Jim_Obj* clause) {
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(clause));
    int nTerms = Jim_ListLength(interp, clause);

    if (nTerms >= 2) {
        const char* secondTerm = Jim_String(interp, Jim_ListGetIndex(interp, clause, 1));
        if (strcmp(secondTerm, "claims") == 0 ||
            strcmp(secondTerm, "wishes") == 0) {
            Jim_FreeNewObj(ret);
            return NULL;
        }
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    jimAppendString(interp, ret, "/someone/");
    jimAppendString(interp, ret, "claims");

    for (int i = 0; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, clause, i));
    }

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* unclaimizeClause(Jim_Obj* clause) {
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(clause));
    size_t nTerms = Jim_ListLength(interp, clause);

    // Omar claims the time is 3
    //   -> the time is 3
    for (size_t i = 2; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, clause, i));
    }

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* whenizeClause(Jim_Obj* clause) {
    // the time is /t/
    //   -> when the time is /t/ /__lambda/ with environment /__env/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(clause));
    size_t nTerms = Jim_ListLength(interp, clause);

    jimAppendString(interp, ret, "when");
    for (int i = 0; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, clause, i));
    }
    jimAppendString(interp, ret, "/__lambda/");
    jimAppendString(interp, ret, "with");
    jimAppendString(interp, ret, "environment");
    jimAppendString(interp, ret, "/__env/");

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* unwhenizeClause(Jim_Obj* clause) {
    // when the time is /t/ /lambda/ with environment /env/
    //   -> the time is /t/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(clause));
    size_t nTerms = Jim_ListLength(interp, clause);

    for (int i = 1; i < nTerms - 4; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, clause, i));
    }

    return ret;
}
static Jim_Obj* subscriptionizeClause(Jim_Obj* notifyClause) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /__env/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(notifyClause));
    size_t nTerms = Jim_ListLength(interp, notifyClause);

    jimAppendString(interp, ret, "subscribe");
    for (int i = 0; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, notifyClause, i));
    }
    jimAppendString(interp, ret, "/__lambda/");
    jimAppendString(interp, ret, "with");
    jimAppendString(interp, ret, "environment");
    jimAppendString(interp, ret, "/__env/");

    return ret;
}
// currently the same as unwhenizeClause, but semantically different
static Jim_Obj* unsubscriptionizeClause(Jim_Obj* subscribeClause) {
    // subscribe the time is /t/ /lambda/ with environment /env/
    //        -> the time is /t/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(subscribeClause));
    size_t nTerms = Jim_ListLength(interp, subscribeClause);

    for (int i = 1; i < nTerms - 4; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, subscribeClause, i));
    }

    return ret;
}

// React to the addition of a new statement: fire any pertinent
// existing Whens & if the new statement is a When, then fire it with
// respect to any pertinent existing statements. 
static void reactToNewStatement(StatementRef ref) {
    // This is just to ensure clause validity.
    Statement* stmt = statementAcquire(db, ref);
    if (stmt == NULL) { return; }
    Jim_Obj* clause = statementClause(stmt);
    assert(clause != NULL);

    Jim_Obj* firstTerm = Jim_ListGetIndex(interp, clause, 0);
    if (firstTerm != NULL && strcmp(Jim_String(interp, firstTerm), "subscribe") == 0) {
        // nothing to do, as subscribe is handled when events are
        // fired
        statementRelease(db, stmt);
        return;
    }

    if (firstTerm != NULL && strcmp(Jim_String(interp, firstTerm), "when") == 0) {
        // Find the query pattern of the when:
        Jim_Obj* pattern = unwhenizeClause(clause);
        Jim_IncrRefCount(pattern);

        if (Jim_ListLength(interp, pattern) == 0) {
            // Empty pattern: When { ... }
            pushRunWhenBlock(
                ref,
                pattern,
                STATEMENT_REF_NULL
            );
        } else {
            // Scan the existing statement set for any
            // already-existing matching statements.
            ResultSet* existingMatchingStatements = dbQuery(db, pattern);
            for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                pushRunWhenBlock(
                    ref,
                    pattern,
                    existingMatchingStatements->results[i]
                );
            }
            free(existingMatchingStatements);

            Jim_Obj* claimizedPattern = claimizeClause(pattern);
            if (claimizedPattern) {
                Jim_IncrRefCount(claimizedPattern);

                existingMatchingStatements = dbQuery(db, claimizedPattern);
                for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                    pushRunWhenBlock(
                        ref,
                        claimizedPattern,
                        existingMatchingStatements->results[i]
                    );
                }
                free(existingMatchingStatements);

                Jim_DecrRefCount(claimizedPattern);
            }
        }

        Jim_DecrRefCount(pattern);
    }

    // Add to DB <Claim Omar is a person>
    // Add to DB <When /someone/ is a person { ... }>
    // React to <Claim Omar is a person>: finds When -> evals
    // React to <When /someone/ is a person>: finds Claim -> evals (DOUBLE EVAL)

    // (is the double eval even bad?)

    // FIXME: What if a when is added that matches us at this point?
    // We're already in the DB, so the when will fire itself with
    // respect to us in the DB, but we'll also see it here, so we'll
    // fire with respect to it in the DB.

    // sequence number? react completion flag?

    // Solution? Some kind of lookaside buffer with a list of patterns
    // that are being contended over? Some kind of locks? Reversible
    // transactions? Like is this whole thing a transaction.

    // Trigger any already-existing reactions to the addition of this
    // statement (look for Whens that are already in the database).
    {
        // the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Jim_Obj* whenizedClause = whenizeClause(clause);
        ResultSet* existingReactingWhens = dbQuery(db, whenizedClause);
        /* trace("Adding stmt: existing reacting whens (%d)", */
        /*       existingReactingWhens->nResults); */
        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Jim_Obj* whenPattern = unwhenizeClause(statementClause(when));
                statementRelease(db, when);

                pushRunWhenBlock(
                    whenRef,
                    whenPattern,
                    ref
                );
            }
        }
        free(existingReactingWhens);

        Jim_FreeNewObj(whenizedClause);
    }

    Jim_Obj* secondTerm = Jim_ListGetIndex(interp, clause, 1);
    if (secondTerm != NULL && strcmp(Jim_String(interp, secondTerm), "claims") == 0) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Jim_Obj* unclaimizedClause = unclaimizeClause(clause);
        Jim_Obj* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        Jim_FreeNewObj(unclaimizedClause);
        Jim_FreeNewObj(whenizedUnclaimizedClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Jim_Obj* unwhenizedWhenPattern = unwhenizeClause(statementClause(when));
                Jim_Obj* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);

                pushRunWhenBlock(
                    whenRef,
                    // takes ownership
                    claimizedUnwhenizedWhenPattern,
                    ref
                );
                statementRelease(db, when);

                Jim_FreeNewObj(unwhenizedWhenPattern);
            }
        }
        free(existingReactingWhens);
    }

    statementRelease(db, stmt);
}

static void Notify(Jim_Obj* toNotify) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /__env/
    Jim_Obj* clauseQuery = subscriptionizeClause(toNotify);
    ResultSet* rs = dbQuery(db, clauseQuery);

    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* subscription = statementAcquire(db, rs->results[i]);
        if (subscription == NULL) { continue; }

        Jim_Obj* subscriptionPattern = unsubscriptionizeClause(statementClause(subscription));
        pushRunSubscriptionBlock(rs->results[i], subscriptionPattern, toNotify);

        statementRelease(db, subscription);
    }

    free(rs);
    Jim_FreeNewObj(clauseQuery);
}

void workerRun(WorkQueueItem item) {
#ifdef TRACY_ENABLE
    TracyCZoneCtx zone;
    if (item.op == ASSERT) {
        TracyCZoneN(ctx, "ASSERT", 1); zone = ctx;
    } else if (item.op == RETRACT) {
        TracyCZoneN(ctx, "RETRACT", 1); zone = ctx;
    } else if (item.op == RUN_WHEN) {
        TracyCZoneN(ctx, "RUN_WHEN", 1); zone = ctx;
    } else if (item.op == RUN_SUBSCRIBE) {
        TracyCZoneN(ctx, "RUN_SUBSCRIBE", 1); zone = ctx;
    } else if (item.op == EVAL) {
        TracyCZoneN(ctx, "EVAL", 1); zone = ctx;
    } else {
        FATAL("workerRun: Unknown item type\n");
    }
#endif

    self->currentItemStartTimestamp = timestamp_get(self->clockid);

    mutexLock(&self->currentItemMutex);
    self->currentItem = item;
    mutexUnlock(&self->currentItemMutex);

    if (item.op == ASSERT) {
        /* printf("Assert (%s)\n", clauseToString(item.assert.clause)); */

        Statement* stmt;
        stmt = dbInsertOrReuseStatement(db, interp, item.assert.clause,
                                        0, NULL,
                                        item.assert.sourceFileName,
                                        item.assert.sourceLineNumber,
                                        MATCH_REF_NULL, NULL);
        if (stmt != NULL) {
            StatementRef ref = statementRef(db, stmt);

            reactToNewStatement(ref);

            dbInflightDecr(db, stmt);
            statementRelease(db, stmt);
        }

        // incremented when pushed to the queue
        Jim_DecrRefCount(item.assert.clause);
        free(item.assert.sourceFileName);

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */
        dbRetractStatements(db, item.retract.pattern);

        // incremented when pushed to the queue
        Jim_DecrRefCount(item.retract.pattern);

    } else if (item.op == RUN_WHEN) {
        /* printf("  when: %d:%d; stmt: %d:%d\n", item.run.when.idx, item.run.when.gen, */
        /*        item.run.stmt.idx, item.run.stmt.gen); */
        runWhenBlock(item.runWhen.when, item.runWhen.whenPattern, item.runWhen.stmt);
        Jim_DecrRefCount(item.runWhen.whenPattern);

    } else if (item.op == RUN_SUBSCRIBE) {
        runSubscribeBlock(item.runSubscribe.subscribeRef, item.runSubscribe.subscribePattern,
                          item.runSubscribe.notifyClause);
        Jim_DecrRefCount(item.runSubscribe.subscribePattern);
        Jim_DecrRefCount(item.runSubscribe.notifyClause);

    } else if (item.op == EVAL) {
        // Used for destructors.
        char* code = item.eval.code;
        int error = Jim_Eval(interp, code);
        if (error == JIM_ERR) {
            Jim_MakeErrorMessage(interp);
            fprintf(stderr, "destructorHelper: (%s) -> (%s)\n",
                    code, Jim_String(interp, Jim_GetResult(interp)));
        }
        free(code);

    } else {
        FATAL("workerRun: Unknown work item op: %d\n", item.op);
    }

    self->currentItemStartTimestamp = 0;
    mutexLock(&self->currentItemMutex);
    self->currentItem = (WorkQueueItem) { .op = NONE };
    mutexUnlock(&self->currentItemMutex);

#ifdef TRACY_ENABLE
    TracyCZoneEnd(zone);
#endif

    // Was this work item marked as I/O-blocked by sysmon? If so, then
    // we'll deactivate this worker thread, because we assume
    // that sysmon spawned a new thread that's more responsive & we
    // don't want to overcrowd the CPUs with threads (they'd start
    // preempting each other and introduce latency).
    if (self->wasObservedAsBlocked) {
        self->wasObservedAsBlocked = false;
        // Donate our entire workqueue before we deactivate.
        while (true) {
            WorkQueueItem item = workQueueTake(self->workQueue);
            if (item.op == NONE) { break; }
            globalWorkQueuePush(item);
        }

        self->isDeactivated = true;
        sem_wait(&self->reactivate);
        self->isDeactivated = false;
    }
}

extern Statement* statementUnsafeGet(Db* db, StatementRef ref);
void traceItem(char* buf, size_t bufsz, WorkQueueItem item) {
    if (item.op == ASSERT) {
        snprintf(buf, bufsz, "Assert (%.100s)",
                 Jim_String(interp, item.assert.clause));

    } else if (item.op == RETRACT) {
        snprintf(buf, bufsz, "Retract (%.100s)",
                 Jim_String(interp, item.retract.pattern));

    } else if (item.op == RUN_WHEN) {
        Statement* when = statementAcquire(db, item.runWhen.when);
        Statement* stmt = statementAcquire(db, item.runWhen.stmt);
        snprintf(buf, bufsz, "Run when(%.100s) pattern(%.100s) stmt(%.100s)",
                 when != NULL ? Jim_String(interp, statementClause(when)) : "NULL",
                 Jim_String(interp, item.runWhen.whenPattern),
                 stmt != NULL ? Jim_String(interp, statementClause(stmt)) : "NULL");
        if (when) statementRelease(db, when);
        if (stmt) statementRelease(db, stmt);

    } else if (item.op == RUN_SUBSCRIBE) {
        Statement* subscribe = statementAcquire(db, item.runSubscribe.subscribeRef);
        snprintf(buf, bufsz, "Run subscribe(%.100s) pattern(%.100s) stmt(%.100s)",
                 subscribe != NULL ? Jim_String(interp, statementClause(subscribe)) : "NULL",
                 Jim_String(interp, item.runSubscribe.subscribePattern),
                 Jim_String(interp, item.runSubscribe.notifyClause));
        if (subscribe) statementRelease(db, subscribe);

    } else if (item.op == EVAL) {
        snprintf(buf, bufsz, "Eval");
    } else if (item.op == NONE) {
        snprintf(buf, bufsz, "NONE");
    } else {
        snprintf(buf, bufsz, "???");
    }
}

ssize_t unsafe_workQueueSize(WorkQueue* q);
__thread unsigned int seedp;
WorkQueueItem workerSteal() {
    int stealee;
    do {
        stealee = rand_r(&seedp) % threadCount;
        if (stealee == self->index) {
            sched_yield();
        }
    } while (stealee == self->index);

    if (threads[stealee].tid == 0 || threads[stealee].workQueue == NULL) {
        return (WorkQueueItem) { .op = NONE };
    }

    return workQueueSteal(threads[stealee].workQueue);
}
void workerLoop() {
    int64_t schedtick = 0;
    for (;;) {
        schedtick++;
        if (interp->sigmask & (1 << SIGUSR1)) {
            // FIXME: I think this signal handler doesn't actually
            // run.
            workerExit();
        }

        // no one is using the interp at this moment, so we can
        // rewind the temp list
        Jim_RewindTempList(interp);

        WorkQueueItem item = { .op = NONE };
        if (schedtick % 61 == 0) {
            item = globalWorkQueueTake();
        }
        if (item.op == NONE) {
            item = workQueueTake(self->workQueue);
        }
        if (item.op == NONE) {
            item = workerSteal();
        }
        if (item.op == NONE) {
            item = globalWorkQueueTake();
        }
        if (item.op == NONE) {
            continue;
        }

        workerRun(item);
    }
 die:
    // Note that our workqueue should be empty at this point.
    fprintf(stderr, "%d: Die\n", self->index);
    workerExit();
}
void workerInit(int index) {
    seedp = time(NULL) + index;

    pthread_setcanceltype(PTHREAD_CANCEL_ASYNCHRONOUS, NULL);

    self = &threads[index];
    if (self->workQueue == NULL) {
        self->workQueue = workQueueNew();
        self->currentItem = (WorkQueueItem) { .op = NONE };
        mutexInit(&self->currentItemMutex);

        self->isDeactivated = false;
        sem_init(&self->reactivate, 0, 0);
    }

    epochThreadInit();

/* #ifdef __linux__ */
/*     if (pthread_getcpuclockid(pthread_self(), &self->clockid)) { */
/*         perror("workerInit: pthread_getcpuclockid failed"); */
/*     } */
/* #else */
    self->clockid = CLOCK_MONOTONIC;
/* #endif */
    self->currentItemStartTimestamp = 0;
    self->index = index;
    self->pthread = pthread_self();

    self->_allocs = 0;
    self->_frees = 0;

#ifdef TRACY_ENABLE
    char threadName[100]; snprintf(threadName, 100, "folk-worker-%d", index);
    TracyCSetThreadName(threadName);
#endif

    interpBoot();
}
void workerExit() {
    // Need this so that this worker doesn't count as still being
    // alive and count toward the worker cap.

    // Donate any remaining items in our local workQueue to the global
    // queue. Otherwise they'd be stranded: workerSteal skips workers
    // whose tid == 0. This matters for self-kill scenarios like a
    // When body whose Hold!/Say replaces its own match's parent —
    // reactToNewStatement pushes the follow-up RUN_WHEN onto the
    // local queue right before SIGUSR1 tears the worker down.
    if (self->workQueue != NULL) {
        while (true) {
            WorkQueueItem item = workQueueTake(self->workQueue);
            if (item.op == NONE) { break; }
            globalWorkQueuePush(item);
        }
    }

    // TODO: Clear everything else out?
    self->tid = 0;
    Jim_FreeInterp(interp);
    epochThreadDestroy();

    pthread_exit(NULL);
}
void* workerMain(void* arg) {
#ifdef __APPLE__
    pid_t tid = pthread_mach_thread_np(pthread_self());
#else
    pid_t tid = gettid();
#endif

    int threadIndex = -1;
    int i;
    for (i = 0; i < THREADS_MAX; i++) {
        pid_t zero = 0;
        if (atomic_compare_exchange_weak(&threads[i].tid, &zero, tid)) {
            threadIndex = i;
            break;
        }
    }
    if (threadIndex == -1) {
        FATAL("folk: workerMain: exceeded THREADS_MAX\n");
    }
    if (i >= threadCount) {
        threadCount = i + 1;
    }
    /* fprintf(stderr, "thread boot %d (thread count %d)\n", threadIndex, threadCount); */
    workerInit(threadIndex);
    workerLoop();
    return NULL;
}
void workerSpawn() {
    pthread_t th;
    pthread_create(&th, NULL, workerMain, NULL);
}
static void workerInfo(int threadIndex) {
    if (threadIndex >= threadCount || threads[threadIndex].tid == 0) {
        /* printf("No thread at index %d\n", threadIndex); */
        return;
    }
    ThreadControlBlock *thread = &threads[threadIndex];

    // Print current operation
    char opBuf[10000];
    traceItem(opBuf, sizeof(opBuf), thread->currentItem);
    printf("Current operation: %s\n", opBuf);

    // Print work queue items
    WorkQueueItem items[100];
    int nitems = unsafe_workQueueCopy(items, 100, thread->workQueue);
    printf("Work queue (%d items):\n", nitems);
    for (int i = 0; i < nitems; i++) {
        char itemBuf[10000];
        traceItem(itemBuf, sizeof(itemBuf), items[i]);
        printf("  %d: %s\n", i, itemBuf);
    }

    // Print timing info
    printf("Current item start timestamp: %" PRId64 "\n", thread->currentItemStartTimestamp);

    int64_t now = timestamp_get(thread->clockid);
    double elapsed = (double)(now - thread->currentItemStartTimestamp) / 1000.0;
    printf("Elapsed time: %.3f us\n", elapsed);
}

void workerReactivateOrSpawn(int64_t msSinceBoot, int targetNotBlockedWorkersCount) {
    int nLivingThreads = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        if (threads[i].tid != 0) {
            nLivingThreads++;
            if (threads[i].isDeactivated) {
                sem_post(&threads[i].reactivate);
                return;
            }
        }
    }
    // Arbitrarily picked: we don't want to have more than 15
    // background threads hanging around.
    if (nLivingThreads > targetNotBlockedWorkersCount + 15) {
        if (msSinceBoot > 10000) {
            // (Don't print a warning before 10 seconds have elapsed
            // since boot, because we expect to have to do a lot of
            // work at startup, and we don't want to spam stderr.)
            /* fprintf(stderr, "folk: workerReactivateOrSpawn: " */
            /*         "Not spawning new thread; too many already\n"); */
        }

        /* { */
        /*     printf("SPAWN NEW WORKER\n" */
        /*            "============================\n"); */
        /*     for (int i = 0; i < THREADS_MAX; i++) { */
        /*         printf("\nthread %d\n" */
        /*                "------------------\n", i); */
        /*         workerInfo(i); */
        /*     } */
        /* } */

        return;
    }
    fprintf(stderr, "folk: workerReactivateOrSpawn: Worker spawn\n");
    workerSpawn();
}

void *webDebugAllocator(void *ptr, size_t size) {
    if (size == 0) {
        if (ptr == NULL) { return NULL; }

        // Check magic number before free
        if (ptr && *(uint32_t*)((char*)ptr - 4 - sizeof(size_t)) != 0xBABE) {
            // Magic number corruption detected
            fprintf(stderr, "debugAllocator: WARNING: Magic number corruption detected\n");
            return NULL;
        }
        size_t allocSize = *(size_t*)((char*)ptr - sizeof(size_t));
        self->_frees += allocSize;
        free((char*)ptr - 4 - sizeof(size_t));
        return NULL;
    }
    else if (ptr) {
        size_t oldSize = *(size_t*)((char*)ptr - sizeof(size_t));
        self->_frees += oldSize;
        void *newAlloc = realloc((char*)ptr - 4 - sizeof(size_t), size + 4 + sizeof(size_t)) + 4 + sizeof(size_t);
        *(size_t*)((char*)newAlloc - sizeof(size_t)) = size;
        self->_allocs += size;
        return newAlloc;
    }
    else {
        void *allocation = malloc(size + 4 + sizeof(size_t));
        if (allocation) {
            *(uint32_t*)allocation = 0xBABE;
            *(size_t*)((char*)allocation + 4) = size;
            self->_allocs += size;
            return (char*)allocation + 4 + sizeof(size_t);
        }
        return NULL;
    }
}
#ifdef TRACY_ENABLE
void *tracyDebugAllocator(void *ptr, size_t size) {
    if (size == 0) {
        TracyCFree(ptr);
        free(ptr);
        return NULL;
    }
    else if (ptr) {
        TracyCFree(ptr);
        void *nptr = realloc(ptr, size);
        TracyCAlloc(nptr, size);
        return nptr;
    }
    else {
        void *ptr = malloc(size);
        TracyCAlloc(ptr, size);
        return ptr;
    }
}
#endif

int main(int argc, char** argv) {
    // Do all setup.

    // Jim_Allocator = webDebugAllocator;

    if (argc == 1) {
        // booting normal Folk (no script passed at command line); set
        // up output redirection.
        outputRedirectionInit(true);
    } else {
        outputRedirectionInit(false);
    }

    // Set up database.
    db = dbNew();

    workQueueInit();

    globalWorkQueueInit();
    blockStatsInit();

#ifdef __linux__
    // Count CPUs so we can set up the thread pool to align with the
    // available cores.
    cpu_set_t cs; CPU_ZERO(&cs);
    sched_getaffinity(0, sizeof(cs), &cs);
    int cpuCount = CPU_COUNT(&cs);
    // printf("main: CPU_COUNT = %d\n", cpuCount);
    assert(cpuCount >= 2);

    int cpuUsableCount = cpuCount - 1; // will exclude CPU 0 later.
#else
    // HACK: for macOS.
    int cpuUsableCount = 8;
#endif

    {
        // Spawn the sysmon thread, which isn't managed the same way
        // as worker threads, and which doesn't run a Folk
        // interpreter. It's just pure C. It's also guaranteed(?) to
        // not run more than every few milliseconds, so it's ok to let
        // it run on the free core.
        sysmonInit(cpuUsableCount > 5 ? 5 : cpuUsableCount);
        pthread_t sysmonTh;
        pthread_create(&sysmonTh, NULL, sysmonMain, NULL);
    }

#ifdef __linux__
    // Disable CPU 0 entirely; we will leave it to Linux. Goal:
    // exclude one CPU from Folk, so that Linux can still accept ssh
    // connections and stuff like that if Folk goes off the rails.
    CPU_CLR(0, &cs);
    sched_setaffinity(0, sizeof(cs), &cs);
#endif

    threadCount = 1; // i.e., this current thread.
    // Set up this thread's slot (slot 0) with tid to exclude other
    // threads from using the slot:
#ifdef __APPLE__
    threads[0].tid = pthread_mach_thread_np(pthread_self());
#else
    threads[0].tid = gettid();
#endif

    // Now spawn cpuUsableCount-1 additional workers.
    for (int i = 0; i < cpuUsableCount - 1; i++) { workerSpawn(); }

    // Now we set up worker 0, which is this main thread itself, which
    // needs to be an active worker, in case we need to do things like
    // GLFW that the OS forces to be on the main thread.

    workerInit(0);

    // We run the boot program in a fake context so that it can run
    // When/Claim/Wish right away _and_ is still running on the main
    // thread (so that on Apple platforms, it can set up the
    // windowing/GPU safely.)
    char *bootFile = argc == 1 ? "boot.folk" : argv[1];
    char code[1024];
    snprintf(code, sizeof(code),
             "apply {{} {set __envStack [list]; set this {%s}; source {%s}}}",
             bootFile, bootFile);
    eval(code);

    workerLoop();
}
