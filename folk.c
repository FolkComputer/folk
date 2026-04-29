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
#include <libzicl.h>

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
__thread Zicl_Interp* interp = NULL;
__thread jmp_buf __onError;
// __onError can only be set once for one call into C; if it's already
// set and you try to set it again (maybe because you called a _Cmd
// wrapper directly), you shouldn't.
__thread bool __onErrorIsSet;

Db* db;

static Clause* ziclObjsToClause(int objc, Zicl_Handle *const objv) {
    Clause* clause = clauseNew(objc);

    const char* str;
    int len;
    for (int i = 0; i < objc; i++) {
        str = Zicl_GetString(objv[i], &len);
        clause->terms[i] = termNew(str, len);
    }
    return clause;
}

Clause* ziclObjToClause(Zicl_Interp* interp, Zicl_Handle* handle) {
    int objc = Zicl_ListLength(interp, handle);
    Clause* clause = clauseNew(objc);
    for (int i = 0; i < objc; i++) {
        Zicl_Handle termObj = Zicl_ListGetItem(*handle, i);
        int len; const char* s = Zicl_GetString(termObj, &len);
        clause->terms[i] = termNew(s, len);
    }
    return clause;
}
static Zicl_Handle termToZiclObj(const Term* term) {
    return Zicl_NewString(termPtr(term), termLen(term));
}
static Zicl_Handle termsToZiclObj(int nTerms, Term* terms[]) {
    Zicl_Handle termObjs[nTerms];
    for (int i = 0; i < nTerms; i++) {
        termObjs[i] = termToZiclObj(terms[i]);
    }
    return Zicl_NewList(termObjs, nTerms);
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
    Zicl_Handle value;
} EnvironmentBinding;
typedef struct Environment {
    int nBindings;
    EnvironmentBinding bindings[];
} Environment;

// This function lives in folk.c and not trie.c (where most
// Clause/matching logic lives) because it operates at the Tcl level,
// building up a mapping of strings to Tcl objects. Caller must free
// the returned Environment*.
Environment* clauseUnify(Clause* a, Clause* b) {
    Environment* env = malloc(sizeof(Environment) + sizeof(EnvironmentBinding)*a->nTerms);
    env->nBindings = 0;

    for (int i = 0; i < a->nTerms && i < b->nTerms; i++) {
        char aVarName[100] = {0}; char bVarName[100] = {0};
        if (trieScanVariable(a->terms[i], aVarName, sizeof(aVarName))) {
            if (aVarName[0] == '.' && aVarName[1] == '.' && aVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName + 3, sizeof(binding->name) - 3);
                binding->value = termsToZiclObj(b->nTerms - i, &b->terms[i]);
            } else if (!trieVariableNameIsNonCapturing(aVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = termToZiclObj(b->terms[i]);
            }
        } else if (trieScanVariable(b->terms[i], bVarName, sizeof(bVarName))) {
            if (bVarName[0] == '.' && bVarName[1] == '.' && bVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName + 3, sizeof(binding->name) - 3);
                binding->value = termsToZiclObj(a->nTerms - i, &a->terms[i]);
            } else if (!trieVariableNameIsNonCapturing(bVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = termToZiclObj(a->terms[i]);
            }
        } else if (!termEq(a->terms[i], b->terms[i])) {
            free(env);
            fprintf(stderr, "clauseUnify: Warning: Unification of (%s) (%s) failed.\n",
                    clauseToString(a), clauseToString(b));
            return NULL;
        }
    }
    return env;
}

// Assert! the time is 3
static int AssertFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    Clause* clause = ziclObjsToClause(argc - 1, argv + 1);

    Zicl_Handle scriptObj = Zicl_GetScriptBeingEvaluated(interp);
    const char* sourceFileName = Zicl_SourceGetFilename(scriptObj);
    if (!sourceFileName) sourceFileName = "<unknown>";
    int sourceLineNumber = Zicl_SourceGetLine(scriptObj);

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
static int RetractFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    Clause* pattern = ziclObjsToClause(argc - 1, argv + 1);

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
                                          Clause *clause, long keepMs, const char *destructorCode,
                                          const char *sourceFileName, int sourceLineNumber) {
/* #ifdef TRACY_ENABLE */
/*     char *s = clauseToString(clause); */
/*     TracyCMessageFmt("hold: %.200s", s); free(s); */
/* #endif */

    StatementRef oldRef; Statement* newStmt;

    newStmt = dbHoldStatement(db, key, version,
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
                           Clause *clause, long keepMs, const char *destructorCode,
                           const char *sourceFileName, int sourceLineNumber) {
    Statement* stmt = HoldStatementGloballyAcquiring(key, version,
                                                     clause, keepMs, destructorCode,
                                                     sourceFileName, sourceLineNumber);
    if (stmt != NULL) {
        dbInflightDecr(db, stmt);
        statementRelease(db, stmt);
    }
}
static int HoldStatementGloballyFunc(Zicl_Interp *interp, int argc, Zicl_Handle *argv) {
    assert(argc == 8);

    const char* sourceFileName;
    long sourceLineNumber;
    sourceFileName = Zicl_String(argv[6]);
    if (sourceFileName == NULL) { return ZICL_ERR; }
    if (Zicl_GetLong(interp, &argv[7], &sourceLineNumber) != ZICL_OK) { return ZICL_ERR; }

    const char *key = Zicl_GetString(argv[1], NULL);
    double version; assert(Zicl_GetDouble(interp, &argv[2], &version) == ZICL_OK);
    Clause *clause = ziclObjToClause(interp, &argv[3]);
    long keepMs; assert(Zicl_GetLong(interp, &argv[4], &keepMs) == ZICL_OK);
    int destructorCodeLen;
    const char* destructorCode = Zicl_GetString(argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    HoldStatementGlobally(key, version,
                          clause, keepMs, destructorCode,
                          sourceFileName, sourceLineNumber);

    return (JIM_OK);
}


static StatementRef Say(Clause* clause, long keepMs,
                        AtomicallyVersion* atomicallyVersion,
                        const char *destructorCode,
                        const char *sourceFileName, int sourceLineNumber) {
    MatchRef parent;
    if (self->currentMatch) {
        parent = matchRef(db, self->currentMatch);

    } else {
        parent = MATCH_REF_NULL;
        char *s = clauseToString(clause);
        fprintf(stderr, "Warning: Creating Say without parent match (%.100s)\n",
                s);
        free(s);
    }

    Statement* stmt;
    stmt = dbInsertOrReuseStatement(db, clause,
                                    keepMs, atomicallyVersion,
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

static int SayWithSourceFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc >= 7);
    Clause* clause = ziclObjsToClause(argc - 6, argv + 6);

    const char* sourceFileName;
    long sourceLineNumber;
    sourceFileName = Zicl_String(argv[1]);
    if (sourceFileName == NULL) { goto err; }
    if (Zicl_GetLong(interp, &argv[2], &sourceLineNumber) != ZICL_OK) {
        goto err;
    }

    long keepMs;
    if (Zicl_GetLong(interp, &argv[3], &keepMs) != ZICL_OK) {
        goto err;
    }

    AtomicallyVersion* atomicallyVersion = NULL;
    const char* atomicallyVersionStr = Zicl_String(argv[4]);
    if (atomicallyVersionStr && strlen(atomicallyVersionStr) > 0) {
        sscanf(atomicallyVersionStr, "(AtomicallyVersion*) %p", &atomicallyVersion);
    }

    int destructorCodeLen;
    const char* destructorCode = Zicl_GetString(argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    if (self->inSubscription) {
        Zicl_SetResultString(interp, "Cannot call Say within Subscribe", -1);
        goto err;
    }

    Say(clause, keepMs, atomicallyVersion,
        destructorCode,
        sourceFileName, (int) sourceLineNumber);
    return JIM_OK;

 err:
    clauseFree(clause);
    return JIM_ERR;
}

static int DestructorFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 2);
    if (self->inSubscription) {
        Zicl_SetResultString(interp, "Cannot create destructor in a subscribe block", -1);
        return JIM_ERR;
    }

    Destructor* d = destructorNew(destructorHelper, strdup(Zicl_String(argv[1])));
    matchAddDestructor(self->currentMatch, d);
    return JIM_OK;
}

static void Notify(Clause* toNotify);
static int NotifyFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc >= 2);

    Clause* toNotify = ziclObjsToClause(argc - 1, argv + 1);
    Notify(toNotify);

    clauseFree(toNotify);
    return JIM_OK;
}

extern int statementParentCount(Statement* stmt);
Zicl_Handle QuerySimple(Zicl_Interp *interp, bool isAtomically, Clause* pattern) {
    ResultSet* rs = dbQuery(db, pattern);

    Zicl_Handle ret = Zicl_NewList(NULL, 0);
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

        Environment* env = clauseUnify(pattern, statementClause(result));
        if (env == NULL) {
            statementRelease(db, result);
            continue;
        }

        Zicl_Handle envDict[(env->nBindings + 1) * 2];
        envDict[0] = Zicl_NewString("__ref", -1);
        char buf[100]; snprintf(buf, 100,  "s%d:%d", rs->results[i].idx, rs->results[i].gen);
        envDict[1] = Zicl_NewString(buf, -1);

        for (int j = 0; j < env->nBindings; j++) {
            envDict[(j+1)*2] = Zicl_NewString(env->bindings[j].name, -1);
            envDict[(j+1)*2+1] = env->bindings[j].value;
        }
        statementRelease(db, result);

        Zicl_Handle resultObj = Zicl_NewDict(envDict, (env->nBindings + 1) * 2);
        Zicl_ListAppend(interp, &ret, resultObj);

        free(env);
    }

    free(rs);
    return ret;
}

static int QuerySimpleFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc >= 3);

    int isAtomically;
    if (Zicl_GetBoolean(interp, &argv[1], &isAtomically) != ZICL_OK) {
        return ZICL_ERR;
    }

    Clause* pattern = ziclObjsToClause(argc - 2, argv + 2);
/* #ifdef TRACY_ENABLE */
/*     char *s = clauseToString(pattern); */
/*     TracyCMessageFmt("query: %.200s", s); free(s); */
/* #endif */

    Zicl_Handle retObj = QuerySimple(interp, isAtomically, pattern);
    clauseFree(pattern);

    Zicl_SetResult(interp, retObj);
    return ZICL_OK;
}

static int StatementAcquireFunc(Zicl_Interp *interp, int argc, Zicl_Handle *argv) {
    assert(argc == 2);

    StatementRef ref;
    assert(sscanf(Zicl_String(argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);

    if (statementAcquire(db, ref) == NULL) {
        Zicl_SetResultString(interp, "Unable to acquire statement.", -1);
        return JIM_ERR;
    }
    return JIM_OK;
}
static int StatementReleaseFunc(Zicl_Interp *interp, int argc, Zicl_Handle *argv) {
    assert(argc == 2);

    StatementRef ref;
    assert(sscanf(Zicl_String(argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);

    statementRelease(db, statementUnsafeGet(db, ref));
    return JIM_OK;
}

static int __scanVariableFunc(Zicl_Interp *interp, int argc, Zicl_Handle *argv) {
    assert(argc == 2);
    char varName[100];
    int len; const char* s = Zicl_GetString(argv[1], &len);
    Term* potentialVarTerm = termNew(s, len);
    if (trieScanVariable(potentialVarTerm, varName, 100)) {
        Zicl_SetResultString(interp, varName, strlen(varName));
    } else {
        Zicl_SetResultBool(interp, false);
    }
    free(potentialVarTerm);
    return JIM_OK;
}
static int __variableNameIsNonCapturingFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 2);
    Zicl_SetResultBool(interp, trieVariableNameIsNonCapturing(Zicl_String(argv[1])));
    return ZICL_OK;
}
static int __startsWithDollarSignFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 2);
    Zicl_SetResultBool(interp, Zicl_String(argv[1])[0] == '$');
    return ZICL_OK;
}
static int __currentMatchRefFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 1);
    if (self->currentMatch == NULL) {
        Zicl_SetResultString(interp, "", 0);
        return ZICL_OK;
    }

    MatchRef ref = matchRef(db, self->currentMatch);
    char ret[100]; snprintf(ret, 100, "m%u:%u", ref.idx, ref.gen);
    Zicl_SetResultString(interp, ret, strlen(ret));
    return ZICL_OK;
}

static int __statementIncompleteChildMatchesCountFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 2);
    StatementRef ref;
    assert(sscanf(Zicl_String(argv[1]), "s%d:%d", &ref.idx, &ref.gen) == 2);
    Statement* stmt = statementAcquire(db, ref);
    if (stmt == NULL) {
        Zicl_SetResultInt(interp, 0);
        return ZICL_OK;
    }
    Zicl_SetResultInt(interp, statementIncompleteChildMatchesCount(db, stmt));
    statementRelease(db, stmt);
    return ZICL_OK;
}
static int __whenOfCurrentMatchIncompleteChildMatchesCountFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 1);
    StatementRef whenRef = STATEMENT_REF_NULL;
    mutexLock(&self->currentItemMutex);
    if (self->currentItem.op == RUN_WHEN) {
        whenRef = self->currentItem.runWhen.when;
    }
    mutexUnlock(&self->currentItemMutex);

    if (statementRefIsNull(whenRef)) { return ZICL_ERR; }

    Statement* when = statementAcquire(db, whenRef);
    if (when == NULL) {
        // This shouldn't happen?
        Zicl_SetResultBool(interp, false);
        return ZICL_OK;
    }

    Zicl_SetResultInt(interp, statementIncompleteChildMatchesCount(db, when));

    statementRelease(db, when);
    return ZICL_OK;
}
static int __isInSubscriptionFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    Zicl_SetResultBool(interp, self->inSubscription);
    return ZICL_OK;
}
static int __isTracyEnabledFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
#ifdef TRACY_ENABLE
    Zicl_SetResultBool(interp, true);
#else
    Zicl_SetResultBool(interp, false);
#endif
    return ZICL_OK;
}
static int __dbFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    char ret[100]; snprintf(ret, 100, "(Db*) %p", db);
    Zicl_SetResultString(interp, ret, strlen(ret));
    return ZICL_OK;
}
static int __threadIdFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    Zicl_SetResultInt(interp, self->index);
    return ZICL_OK;
}

static int __setFreshAtomicallyVersionOnKeyFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 2);
    const char* key = Zicl_String(argv[1]);
    self->currentAtomicallyVersion =
        dbFreshAtomicallyVersionOnKey(db, key,
                                      matchRef(db, self->currentMatch));
    matchSetAtomicallyVersion(self->currentMatch, self->currentAtomicallyVersion);
    return ZICL_OK;
}
static int __currentAtomicallyVersionFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    assert(argc == 1);
    if (self->currentAtomicallyVersion == NULL) {
        Zicl_SetResultString(interp, "", -1);
    } else {
        char ret[100];
        snprintf(ret, 100, "(AtomicallyVersion*) %p",
                 self->currentAtomicallyVersion);
        Zicl_SetResultString(interp, ret, strlen(ret));
    }
    return ZICL_OK;
}

static int setpgrpFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv) {
    int ret = setpgrp();
    if (ret != -1) {
        return ZICL_OK;
    } else {
        Zicl_SetResultString(interp, strerror(errno), -1);
        return ZICL_ERR;
    }
}
static int exitFunc(Zicl_Interp *interp, int argc, Zicl_Handle *argv) {
    assert(argc == 2);
    long exitCode; Zicl_GetLong(interp, &argv[1], &exitCode);

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

static void interpBoot() {
    interp = Zicl_CreateInterp();

    // outputRedirectionInterpSetup(interp);

    Zicl_CreateCommand(interp, "Assert!", AssertFunc);
    Zicl_CreateCommand(interp, "Retract!", RetractFunc);
    Zicl_CreateCommand(interp, "HoldStatementGlobally!", HoldStatementGloballyFunc);

    Zicl_CreateCommand(interp, "NotifyImpl", NotifyFunc);

    Zicl_CreateCommand(interp, "SayWithSource", SayWithSourceFunc);
    Zicl_CreateCommand(interp, "Destructor", DestructorFunc);

    Zicl_CreateCommand(interp, "QuerySimple!", QuerySimpleFunc);

    Zicl_CreateCommand(interp, "StatementAcquire!", StatementAcquireFunc);
    Zicl_CreateCommand(interp, "StatementRelease!", StatementReleaseFunc);

    Zicl_CreateCommand(interp, "__scanVariable", __scanVariableFunc);
    Zicl_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc);
    Zicl_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc);
    Zicl_CreateCommand(interp, "__currentMatchRef", __currentMatchRefFunc);
    Zicl_CreateCommand(interp, "__statementIncompleteChildMatchesCount", __statementIncompleteChildMatchesCountFunc);
    Zicl_CreateCommand(interp, "__whenOfCurrentMatchIncompleteChildMatchesCount", __whenOfCurrentMatchIncompleteChildMatchesCountFunc);
    Zicl_CreateCommand(interp, "__isInSubscription", __isInSubscriptionFunc);

    Zicl_CreateCommand(interp, "__isTracyEnabled", __isTracyEnabledFunc);
    Zicl_CreateCommand(interp, "__blockRuntimeStats", __blockRuntimeStatsFunc);

    Zicl_CreateCommand(interp, "__db", __dbFunc);
    Zicl_CreateCommand(interp, "__threadId", __threadIdFunc);

    Zicl_CreateCommand(interp, "__setFreshAtomicallyVersionOnKey", __setFreshAtomicallyVersionOnKeyFunc);
    Zicl_CreateCommand(interp, "__currentAtomicallyVersion", __currentAtomicallyVersionFunc);

    Zicl_CreateCommand(interp, "setpgrp", setpgrpFunc);
    Zicl_CreateCommand(interp, "Exit!", exitFunc);

    if (Zicl_EvalFile(interp, "prelude.tcl") != ZICL_OK) {
        Zicl_MakeErrorMessage(interp);
        FATAL("prelude: %s\n", Zicl_String(Zicl_GetResult(interp)));
    }
}
void eval(const char* code) {
    if (interp == NULL) { interpBoot(); }

    int error = Zicl_EvalObject(interp, Zicl_NewString(code, -1));
    if (error == ZICL_ERR) {
        Zicl_MakeErrorMessage(interp);
        fprintf(stderr, "eval: %s\n", Zicl_String(Zicl_GetResult(interp)));
        Zicl_InterpDestroy(interp);
        exit(EXIT_FAILURE);
    }
}

//////////////////////////////////////////////////////////
// Evaluator
//////////////////////////////////////////////////////////

void workerExit();

static int runBlock(Clause* bodyPattern, Clause* toUnifyWith, const Term* body,
                    const char *sourceFileName, int sourceLineNumber,
                    Zicl_Handle envStackObj) {
    Zicl_Handle bodyObj = termToZiclObj(body);
    Zicl_SourceSetInfo(bodyObj, sourceFileName, sourceLineNumber);

    {
        // Figure out all the bound match variables by unifying when & stmt.
        Environment* env = clauseUnify(bodyPattern, toUnifyWith);
        if (env == NULL) {
            Zicl_DecrRefCount(bodyObj);
            return ZICL_OK;
        }

        if (env->nBindings > 50) {
            fprintf(stderr, "runBlock: Too many bindings in env: %d\n",
                    env->nBindings);
            Zicl_DecrRefCount(bodyObj);
            free(env);
            return ZICL_ERR;
        }

        Zicl_Handle objs[env->nBindings*2];
        for (int i = 0; i < env->nBindings; i++) {
            objs[i*2] = Zicl_NewString(env->bindings[i].name, -1);
            objs[i*2 + 1] = env->bindings[i].value;
        }

        Zicl_Handle boundEnvObj = Zicl_NewDict(objs, env->nBindings*2);
        Zicl_ListAppend(interp, &envStackObj, boundEnvObj);

        free(env);
    }

    // Rule: you should never be holding a lock while doing a Tcl evaluation.
    Zicl_IncrSignalDepth(interp);
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

        // Build a one-command list {evaluateBlock body envStack} and eval it.
        Zicl_Handle objv[] = {
            Zicl_NewString("evaluateBlock", -1),
            bodyObj,
            envStackObj
        };
        int64_t t0 = timestamp_get(CLOCK_MONOTONIC);
        error = Zicl_EvalObject(interp, Zicl_NewList(objv, 3));
        blockStatsUpdate(sourceFileName, sourceLineNumber,
                         timestamp_get(CLOCK_MONOTONIC) - t0);

#ifdef TRACY_ENABLE
        ___tracy_emit_zone_end(ctx);
#endif
    }
    Zicl_DecrSignalDepth(interp);

    return error;
}

static void runWhenBlock(StatementRef whenRef, Clause* whenPattern, StatementRef stmtRef) {
    // Dereference refs. if any fail, then skip this work item.
    // Exception: stmtRef can be a null ref if and only if whenPattern
    // is {}.
    Statement* when = NULL;
    Statement* stmt = NULL;
    when = statementAcquire(db, whenRef);
    if (when == NULL) { return; }

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

    Clause* whenClause = statementClause(when);
    Clause* stmtClause = stmt == NULL ? whenPattern : statementClause(stmt);

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
                    whenAtomicallyVersion, clauseToString(statementClause(when)),
                    stmtAtomicallyVersion, clauseToString(statementClause(stmt)));
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

    if (!self->currentMatch) {
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

    assert(whenClause->nTerms >= 5);

    // when the time is /t/ /body/ with environment /capturedEnvStack/
    const Term* body = whenClause->terms[whenClause->nTerms - 4];
    const Term* capturedEnvStack = whenClause->terms[whenClause->nTerms - 1];
    Zicl_Handle envStackObj = termToZiclObj(capturedEnvStack);

    int error = runBlock(whenPattern, stmtClause, body,
                         statementSourceFileName(when),
                         statementSourceLineNumber(when),
                         envStackObj);

    if (self->currentAtomicallyVersion != NULL) {
        dbAtomicallyVersionInflightDecr(db, self->currentAtomicallyVersion);
    }

    statementRelease(db, when);
    if (stmt != NULL) { statementRelease(db, stmt); }

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;

    if (error == ZICL_ERR) {
        Zicl_MakeErrorMessage(interp);
        int len;
        const char *errorMessage = Zicl_GetString(Zicl_GetResult(interp), &len);
        int bodyLen = termLen(body);
        if (bodyLen > 100) bodyLen = 100;
        fprintf(stderr, "Uncaught error running When (%.*s):\n  %s\n",
                bodyLen, termPtr(body), errorMessage);

    } else if (error == ZICL_SIGNAL) {
        workerExit();
    }
}

// Caller is responsible for freeing passed in clauses
static void runSubscribeBlock(StatementRef subscribeRef, Clause* subscribePattern,
                              Clause* notifyClause) {
    Statement* subscribeStmt = statementAcquire(db, subscribeRef);
    if (subscribeStmt == NULL) {  return; }

    Clause* subscribeClause = statementClause(subscribeStmt);
    assert(subscribeClause->nTerms >= 5);

    self->currentMatch = NULL;
    self->inSubscription = true;

    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /capturedEnvStack/
    const Term* body = subscribeClause->terms[subscribeClause->nTerms - 4];
    const Term* capturedEnvStack = subscribeClause->terms[subscribeClause->nTerms - 1];
    Zicl_Handle envStackObj = termToZiclObj(capturedEnvStack);

    int error = runBlock(subscribePattern, notifyClause, body,
                         statementSourceFileName(subscribeStmt),
                         statementSourceLineNumber(subscribeStmt),
                         envStackObj);

    self->inSubscription = false;
    statementRelease(db, subscribeStmt);

    // TODO: Remove duplication of this error handling with runWhenBlock.

    if (error == ZICL_ERR) {
        Zicl_MakeErrorMessage(interp);
        int len;
        const char *errorMessage = Zicl_GetString(Zicl_GetResult(interp), &len);
        int bodyLen = termLen(body);
        if (bodyLen > 100) bodyLen = 100;
        fprintf(stderr, "Fatal (uncaught) error running When (%.*s):\n  %s\n",
                bodyLen, termPtr(body), errorMessage);
        Zicl_InterpDestroy(interp);
        exit(EXIT_FAILURE);

    } else if (error == ZICL_SIGNAL) {
        workerExit();
    }
}

// Copies the whenPattern Clause and all terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunWhenBlock(StatementRef whenRef, Clause* whenPattern, StatementRef stmtRef) {
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
       .runWhen = {
           .when = whenRef,
           .whenPattern = clauseDup(whenPattern),
           .stmt = stmtRef
       }
    });
}

// Copies the clauses and all their terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunSubscriptionBlock(StatementRef subscribeRef, Clause* subscribePattern,
                              Clause* notifyClause) {
    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RUN_SUBSCRIBE,
       .runSubscribe = {
            .subscribeRef = subscribeRef,
            .subscribePattern = clauseDup(subscribePattern),
            .notifyClause = clauseDup(notifyClause)
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
// shouldn't be claimized. Returns a new heap-allocated Clause* that
// must be freed by the caller.
Clause* claimizeClause(Clause* clause) {
    if (clause->nTerms >= 2 &&
        (termEqString(clause->terms[1], "claims") ||
         termEqString(clause->terms[1], "wishes"))) {
        return NULL;
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    Clause* ret = clauseNew(2 + clause->nTerms);
    ret->terms[0] = TERM_STATIC("/someone/"); ret->terms[1] = TERM_STATIC("claims");
    for (int i = 0; i < clause->nTerms; i++) {
        ret->terms[2 + i] = clause->terms[i];
    }
    return ret;
}
static Clause* unclaimizeClause(Clause* clause) {
    // Omar claims the time is 3
    //   -> the time is 3
    Clause* ret = clauseNew(clause->nTerms - 2);
    for (int i = 2; i < clause->nTerms; i++) {
        ret->terms[i - 2] = clause->terms[i];
    }
    return ret;
}
static Clause* whenizeClause(Clause* clause) {
    // the time is /t/
    //   -> when the time is /t/ /__lambda/ with environment /__env/
    Clause* ret = clauseNew(clause->nTerms + 5);
    ret->terms[0] = TERM_STATIC("when");
    for (int i = 0; i < clause->nTerms; i++) {
        ret->terms[1 + i] = clause->terms[i];
    }
    ret->terms[1 + clause->nTerms] = TERM_STATIC("/__lambda/");
    ret->terms[2 + clause->nTerms] = TERM_STATIC("with");
    ret->terms[3 + clause->nTerms] = TERM_STATIC("environment");
    ret->terms[4 + clause->nTerms] = TERM_STATIC("/__env/");
    return ret;
}
static Clause* unwhenizeClause(Clause* whenClause) {
    // when the time is /t/ /lambda/ with environment /env/
    //   -> the time is /t/
    Clause* ret = clauseNew(whenClause->nTerms - 5);
    for (int i = 1; i < whenClause->nTerms - 4; i++) {
        ret->terms[i - 1] = whenClause->terms[i];
    }
    return ret;
}
static Clause* subscriptionizeClause(Clause* notifyClause) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /__env/
    Clause* ret = clauseNew(notifyClause->nTerms + 5);
    ret->terms[0] = TERM_STATIC("subscribe");
    for (int i = 0; i < notifyClause->nTerms; i++) {
        ret->terms[1 + i] = notifyClause->terms[i];
    }
    ret->terms[1 + notifyClause->nTerms] = TERM_STATIC("/__lambda/");
    ret->terms[2 + notifyClause->nTerms] = TERM_STATIC("with");
    ret->terms[3 + notifyClause->nTerms] = TERM_STATIC("environment");
    ret->terms[4 + notifyClause->nTerms] = TERM_STATIC("/__env/");
    return ret;
}
// currently the same as unwhenizeClause, but semantically different
static Clause* unsubscriptionizeClause(Clause* subscribeClause) {
    // subscribe the time is /t/ /lambda/ with environment /env/
    //        -> the time is /t/
    Clause* ret = clauseNew(subscribeClause->nTerms - 5);
    for (int i = 1; i < subscribeClause->nTerms - 4; i++) {
        ret->terms[i - 1] = subscribeClause->terms[i];
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

    Clause* clause = statementClause(stmt);
    assert(clause != NULL);

    if (termEqString(clause->terms[0], "subscribe")) {
        // nothing to do, as subscribe is handled when events are
        // fired
        statementRelease(db, stmt);
        return;
    }

    if (termEqString(clause->terms[0], "when")) {
        // Find the query pattern of the when:
        Clause* pattern = unwhenizeClause(clause);
        if (pattern->nTerms == 0) {
            // Empty pattern: When { ... }
            pushRunWhenBlock(ref, pattern, STATEMENT_REF_NULL);
            clauseFreeBorrowed(pattern);

        } else {
            // Scan the existing statement set for any
            // already-existing matching statements.
            ResultSet* existingMatchingStatements = dbQuery(db, pattern);
            for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                pushRunWhenBlock(ref, pattern,
                                 existingMatchingStatements->results[i]);
            }
            free(existingMatchingStatements);

            Clause* claimizedPattern = claimizeClause(pattern);
            if (claimizedPattern) {
                existingMatchingStatements = dbQuery(db, claimizedPattern);
                for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                    pushRunWhenBlock(ref, claimizedPattern,
                                     existingMatchingStatements->results[i]);
                }
                free(existingMatchingStatements);
            }

            // pattern and claimizedPattern don't allocate any new terms,
            // so just free the clause structs themselves.
            clauseFreeBorrowed(pattern);
            clauseFreeBorrowed(claimizedPattern);
        }
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
        Clause* whenizedClause = whenizeClause(clause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedClause);
        /* trace("Adding stmt: existing reacting whens (%d)", */
        /*       existingReactingWhens->nResults); */
        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Clause* whenPattern = unwhenizeClause(statementClause(when));

                pushRunWhenBlock(whenRef, whenPattern, ref);

                statementRelease(db, when);
                clauseFreeBorrowed(whenPattern); // doesn't own any terms.
            }
        }
        free(existingReactingWhens);

        clauseFreeBorrowed(whenizedClause); // doesn't own any terms.
    }
    if (clause->nTerms >= 2 && termEqString(clause->terms[1], "claims")) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Clause* unclaimizedClause = unclaimizeClause(clause);
        Clause* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        clauseFreeBorrowed(unclaimizedClause);
        clauseFreeBorrowed(whenizedUnclaimizedClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Clause* unwhenizedWhenPattern = unwhenizeClause(statementClause(when));
                Clause* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);

                pushRunWhenBlock(whenRef, claimizedUnwhenizedWhenPattern, ref);

                statementRelease(db, when);
                clauseFreeBorrowed(unwhenizedWhenPattern);
                clauseFreeBorrowed(claimizedUnwhenizedWhenPattern);
            }
        }
        free(existingReactingWhens);
    }
    statementRelease(db, stmt);
}

static void Notify(Clause* toNotify) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/ with environment /__env/
    Clause* query = subscriptionizeClause(toNotify);
    ResultSet* rs = dbQuery(db, query);

    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* subscription = statementAcquire(db, rs->results[i]);
        if (subscription == NULL) { continue; }

        Clause* subscriptionPattern = unsubscriptionizeClause(statementClause(subscription));

        pushRunSubscriptionBlock(rs->results[i], subscriptionPattern, toNotify);
        free(subscriptionPattern); // doesn't own any terms.

        statementRelease(db, subscription);
    }

    free(rs);
    free(query);
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
        stmt = dbInsertOrReuseStatement(db, item.assert.clause,
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
        free(item.assert.sourceFileName);

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */

        dbRetractStatements(db, item.retract.pattern);
        clauseFree(item.retract.pattern);

    } else if (item.op == RUN_WHEN) {
        /* printf("  when: %d:%d; stmt: %d:%d\n", item.run.when.idx, item.run.when.gen, */
        /*        item.run.stmt.idx, item.run.stmt.gen); */
        runWhenBlock(item.runWhen.when, item.runWhen.whenPattern, item.runWhen.stmt);
        clauseFree(item.runWhen.whenPattern);

    } else if (item.op == RUN_SUBSCRIBE) {
        runSubscribeBlock(item.runSubscribe.subscribeRef, item.runSubscribe.subscribePattern,
                          item.runSubscribe.notifyClause);
        clauseFree(item.runSubscribe.subscribePattern);
        clauseFree(item.runSubscribe.notifyClause);

    } else if (item.op == EVAL) {
        // Used for destructors.
        char* code = item.eval.code;
        int error = Zicl_EvalObject(interp, Zicl_NewString(code, -1));
        if (error == ZICL_ERR) {
            Zicl_MakeErrorMessage(interp);
            fprintf(stderr, "destructorHelper: (%s) -> (%s)\n",
                    code, Zicl_String(Zicl_GetResult(interp)));
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
    int threadIndex = self->index;
    if (item.op == ASSERT) {
        snprintf(buf, bufsz, "Assert (%.100s)",
                 clauseToString(item.assert.clause));
    } else if (item.op == RETRACT) {
        snprintf(buf, bufsz, "Retract (%.100s)",
                 clauseToString(item.retract.pattern));
    } else if (item.op == RUN_WHEN) {
        Statement* when = statementUnsafeGet(db, item.runWhen.when);
        Statement* stmt = statementUnsafeGet(db, item.runWhen.stmt);
        snprintf(buf, bufsz, "Run when(%.100s) pattern(%.100s) stmt(%.100s)",
                 when != NULL ? clauseToString(statementClause(when)) : "NULL",
                 clauseToString(item.runWhen.whenPattern),
                 stmt != NULL ? clauseToString(statementClause(stmt)) : "NULL");
    } else if (item.op == RUN_SUBSCRIBE) {
        Statement* subscribe = statementUnsafeGet(db, item.runSubscribe.subscribeRef);
        snprintf(buf, bufsz, "Run subscribe(%.100s) pattern(%.100s) stmt(%.100s)",
                 subscribe != NULL ? clauseToString(statementClause(subscribe)) : "NULL",
                 clauseToString(item.runSubscribe.subscribePattern),
                 clauseToString(item.runSubscribe.notifyClause));
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
        if (Zicl_GetSigmask(interp) & (1 << SIGUSR1)) {
            workerExit();
        }

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
    Zicl_InitLocalHeap();

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

    // TODO: Clear everything else out?
    self->tid = 0;

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

    outputRedirectionInit();

    // Set up database.
    db = dbNew();

    workQueueInit();

    globalWorkQueueInit();
    blockStatsInit();

    Zicl_SetGlobalStdout(realStdout);
    Zicl_SetGlobalStderr(realStderr);
    Zicl_InitGlobals();

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
    // for (int i = 0; i < cpuUsableCount - 1; i++) { workerSpawn(); }

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
