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

#include <libzicl.h>

#define STB_DS_IMPLEMENTATION
#include "vendor/stb_ds.h"

#include "vendor/c11-queues/mpmc_queue.h"

#include "folk-zicl.h"
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
    Zicl_Value value;
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
Environment* clauseUnify(const Zicl_List* a, const Zicl_List* b) {
    int aLen = Zicl_ListLength(a);
    int bLen = Zicl_ListLength(b);

    const Zicl_Value* aTerms = Zicl_ListItems(a);
    const Zicl_Value* bTerms = Zicl_ListItems(b);

    Environment* env = malloc(sizeof(Environment) + sizeof(EnvironmentBinding)*aLen);
    env->nBindings = 0;

    for (int i = 0; i < aLen && i < bLen; i++) {
        char aVarName[100] = {0}; char bVarName[100] = {0};
        if (trieScanVariable(aTerms[i], aVarName, sizeof(aVarName))) {
            if (aVarName[0] == '.' && aVarName[1] == '.' && aVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName + 3, sizeof(binding->name) - 3);
                binding->value = Zicl_BoxList(ziclNewList(bTerms + i, bLen - i));
            } else if (!trieVariableNameIsNonCapturing(aVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = Zicl_Borrow(bTerms[i]);
            }
        } else if (trieScanVariable(bTerms[i], bVarName, sizeof(bVarName))) {
            if (bVarName[0] == '.' && bVarName[1] == '.' && bVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName + 3, sizeof(binding->name) - 3);
                binding->value = Zicl_BoxList(ziclNewList(aTerms + i, aLen - i));
            } else if (!trieVariableNameIsNonCapturing(bVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = Zicl_Borrow(aTerms[i]);
            }
        } else if (!ziclEquals(aTerms[i], bTerms[i])) {
            free(env);
            fprintf(stderr, "clauseUnify: Unification of (%s) (%s) failed\n",
                    ziclListString((Zicl_List *)a), ziclListString((Zicl_List *)b));
            return NULL;
        }
    }
    return env;
}

// Assert! the time is 3
static int AssertFunc(Zicl_Interp* interp, int argc, Zicl_Shimmerable *argv) {
    Zicl_List* clause = ziclNewListFromShimmerables(argv + 1, argc - 1);
    Zicl_MakeCrossthread(Zicl_BoxList(clause));

    Zicl_Value scriptObj = Zicl_EvalFrameScript(interp, Zicl_CurrentEvalFrameIdx(interp));
    const char* sourceFileName = "<unknown>";
    int sourceLineNumber = -1;
    const Zicl_Source *asSource = Zicl_AsSource(scriptObj);
    if (asSource) {
        if (Zicl_IsSome(asSource->file_name)) {
            sourceFileName = ziclString(Zicl_Unwrap(asSource->file_name));
        }
        sourceLineNumber = asSource->line_no;
    }

    appropriateWorkQueuePush((WorkQueueItem) {
        .op = ASSERT,
        .assert = {
            .clause = clause,
            .sourceFileName = strdup(sourceFileName),
            .sourceLineNumber = sourceLineNumber,
        }
    });

    return ZICL_OK;
}
// Retract! the time is /t/
static int RetractFunc(Zicl_Interp* interp, int argc, Zicl_Shimmerable *argv) {
    Zicl_List* pattern = ziclNewListFromShimmerables(argv + 1, argc - 1);
    Zicl_MakeCrossthread(Zicl_BoxList(pattern));

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RETRACT,
       .retract = { .pattern = pattern }
    });

    return ZICL_OK;
}

static void reactToNewStatement(StatementRef ref);

int64_t _Atomic latestVersion = 0; // TODO: split by key?
// Note: returns an acquired statement that the caller should release.
Statement* HoldStatementGloballyAcquiring(const char *key, double version,
                                          Zicl_List *clause, long keepMs, const char *destructorCode,
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
                           Zicl_List *clause, long keepMs, const char *destructorCode,
                           const char *sourceFileName, int sourceLineNumber) {
    Statement* stmt = HoldStatementGloballyAcquiring(key, version,
                                                     clause, keepMs, destructorCode,
                                                     sourceFileName, sourceLineNumber);
    if (stmt != NULL) {
        dbInflightDecr(db, stmt);
        statementRelease(db, stmt);
    }
}
static int HoldStatementGloballyFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    int rc = 0;
    assert(argc == 8);

    const char* sourceFileName = ziclShimString(&argv[6]);
    long sourceLineNumber; ZICL_TRY(Zicl_GetLong(interp, &argv[7], &sourceLineNumber), rc);
    const char *key = ziclShimString(&argv[1]);
    double version; ZICL_TRY(Zicl_GetDouble(interp, &argv[2], &version), rc);
    long keepMs; ZICL_TRY(Zicl_GetLong(interp, &argv[4], &keepMs), rc);
    int destructorCodeLen;
    const char* destructorCode = ziclShimGetString(&argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) destructorCode = NULL;
    Zicl_List* dupedClause; ZICL_TRY(Zicl_DupAsList(interp, Zicl_Current(&argv[3]), &dupedClause), rc);

    HoldStatementGlobally(key, version,
                          dupedClause, keepMs, destructorCode,
                          sourceFileName, sourceLineNumber);

    return ZICL_OK;
}

/* Takes ownership of `clause`. */
static StatementRef Say(Zicl_List* clause, long keepMs,
                        AtomicallyVersion* atomicallyVersion,
                        const char *destructorCode,
                        const char *sourceFileName, int sourceLineNumber) {
    MatchRef parent;
    if (self->currentMatch) {
        parent = matchRef(db, self->currentMatch);

    } else {
        parent = MATCH_REF_NULL;
        const char *s = ziclListString(clause);
        fprintf(stderr, "Warning: Creating unparented Say (%.100s)\n", s);
    }

    Statement* stmt;
    stmt = dbInsertOrReuseStatement(db, clause, keepMs,
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

static int SayWithSourceFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc >= 7);
    Zicl_List* clause = ziclNewListFromShimmerables(argv + 6, argc - 6);

    const char* sourceFileName = ziclShimString(&argv[1]);

    int rc = ZICL_OK;
    long sourceLineNumber; ZICL_TRY(Zicl_GetLong(interp, &argv[2], &sourceLineNumber), rc);
    long keepMs; ZICL_TRY(Zicl_GetLong(interp, &argv[3], &keepMs), rc);

    AtomicallyVersion* atomicallyVersion = NULL;
    const char* atomicallyVersionStr = ziclShimString(&argv[4]);
    if (atomicallyVersionStr && strlen(atomicallyVersionStr) > 0) {
        sscanf(atomicallyVersionStr, "(AtomicallyVersion*) %p", &atomicallyVersion);
    }

    int destructorCodeLen;
    const char* destructorCode = ziclShimGetString(&argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    if (self->inSubscription) {
        Zicl_SetResultString(interp, "Cannot call Say within Subscribe", -1);
        return (rc = ZICL_ERR);
    }

    Say(clause, keepMs,
        atomicallyVersion, destructorCode,
        sourceFileName, (int) sourceLineNumber);
    return ZICL_OK;
}

static int DestructorFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    if (self->inSubscription) {
        return Zicl_SetErrorString(interp, "Cannot create destructor in a subscribe block", -1);
    }

    Destructor* d = destructorNew(destructorHelper,
                                  strdup(ziclShimString(&argv[1])));
    matchAddDestructor(self->currentMatch, d);
    return ZICL_OK;
}

static void Notify(Zicl_List* toNotify);
static int NotifyFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc >= 2);

    Notify(ziclNewListFromShimmerables(argv + 1, argc - 1));
    return ZICL_OK;
}

extern int statementParentCount(Statement* stmt);
Zicl_List* QuerySimple(bool isAtomically, Zicl_List* pattern) {
    ResultSet* rs = dbQuery(db, pattern);

    Zicl_List* ret = ziclNewList(NULL, 0);
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
        defer { for (int j = 0; j < env->nBindings; j++) Zicl_Release(env->bindings[j].value); }
        if (env == NULL) {
            statementRelease(db, result);
            continue;
        }

        Zicl_Dict* envDict = ziclNewDict(NULL, 0);
        defer { Zicl_ReleaseDict(envDict); }
        char buf[100]; snprintf(buf, 100,  "s%d:%d", rs->results[i].idx, rs->results[i].gen);
        ziclDictPut(envDict, ziclNewString("__ref", -1), ziclNewString(buf, -1));

        for (int j = 0; j < env->nBindings; j++) {
            ziclDictPut(envDict, ziclNewString(env->bindings[j].name, -1), env->bindings[j].value);
        }

        ziclListAppend(ret, Zicl_BoxDict(envDict));

        statementRelease(db, result);
        free(env);
    }

    free(rs);
    return ret;
}

static int QuerySimpleFunc(Zicl_Interp* interp, int argc, Zicl_Shimmerable *argv) {
    int rc = ZICL_OK;
    assert(argc >= 3);

    int isAtomically; ZICL_TRY(Zicl_GetBoolean(interp, &argv[1], &isAtomically), rc);

    Zicl_List* pattern = ziclNewListFromShimmerables(argv + 2, argc - 2);
    defer { Zicl_ReleaseList(pattern); }

    Zicl_List* queried = QuerySimple(isAtomically, pattern);
    Zicl_SetResultOwning(interp, Zicl_BoxList(queried));

    return ZICL_OK;
}

static int StatementAcquireFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);

    StatementRef ref;
    int parsed = sscanf(ziclShimString(&argv[1]), "s%d:%d", &ref.idx, &ref.gen);
    if (parsed != 2) return ZICL_USAGE;

    if (statementAcquire(db, ref) == NULL) {
        Zicl_SetResultString(interp, "Unable to acquire statement.", -1);
        return ZICL_ERR;
    }
    return ZICL_OK;
}
static int StatementReleaseFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);

    StatementRef ref;
    int parsed = sscanf(ziclShimString(&argv[1]), "s%d:%d", &ref.idx, &ref.gen);
    if (parsed != 2) return ZICL_USAGE;

    statementRelease(db, statementUnsafeGet(db, ref));
    return ZICL_OK;
}
static int __statementOfCurrentMatchSourceInfoFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);

    StatementRef stmtRef = STATEMENT_REF_NULL;
    mutexLock(&self->currentItemMutex);
    if (self->currentItem.op == RUN_WHEN) {
        stmtRef = self->currentItem.runWhen.stmt;
    }
    mutexUnlock(&self->currentItemMutex);

    if (statementRefIsNull(stmtRef)) {
        Zicl_SetEmptyResult(interp);
        return ZICL_OK;
    }

    Statement* stmt = statementAcquire(db, stmtRef);
    if (stmt == NULL) return Zicl_SetEmptyResult(interp);
    defer { statementRelease(db, stmt); }

    const char* fileName = statementSourceFileName(stmt);
    int lineNumber = statementSourceLineNumber(stmt);
    Zicl_Value result[2] = {
        ziclNewString(fileName ? fileName : "", -1),
        Zicl_NewLong(lineNumber),
    };
    int resultN = sizeof(result)/sizeof(Zicl_Value);
    defer { Zicl_ReleaseArrayItems(result, resultN); }
    Zicl_SetResultOwning(interp, Zicl_BoxList(ziclNewList(result, resultN)));

    return ZICL_OK;
}

static int __scanVariableFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    char varName[100];
    if (trieScanVariable(Zicl_Current(&argv[1]), varName, 100)) {
        return Zicl_SetResultString(interp, varName, -1);
    } else {
        return Zicl_SetResultBool(interp, false);
    }
}
static int __variableNameIsNonCapturingFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    Zicl_SetResultBool(interp, trieVariableNameIsNonCapturing(ziclShimString(&argv[1])));
    return ZICL_OK;
}
static int __startsWithDollarSignFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    Zicl_SetResultBool(interp, ziclShimString(&argv[1])[0] == '$');
    return ZICL_OK;
}
static int __currentMatchRefFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    if (self->currentMatch == NULL) {
        Zicl_SetEmptyResult(interp);
        return ZICL_OK;
    }

    MatchRef ref = matchRef(db, self->currentMatch);
    char ret[100]; snprintf(ret, 100, "m%u:%u", ref.idx, ref.gen);
    Zicl_SetResultString(interp, ret, strlen(ret));
    return ZICL_OK;
}
static int __statementIncompleteChildMatchesCountFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);

    StatementRef ref;
    int parsed = sscanf(ziclShimString(&argv[1]), "s%d:%d", &ref.idx, &ref.gen);
    if (parsed != 2) return ZICL_USAGE;

    Statement* stmt = statementAcquire(db, ref);
    if (stmt == NULL) return Zicl_SetResultLong(interp, 0);
    defer { statementRelease(db, stmt); }

    return Zicl_SetResultLong(interp, statementIncompleteChildMatchesCount(db, stmt));
}
static int __whenOfCurrentMatchIncompleteChildMatchesCountFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
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
        return Zicl_SetResultBool(interp, false);
    }
    defer { statementRelease(db, when); }

    return Zicl_SetResultLong(interp, statementIncompleteChildMatchesCount(db, when));
}
static int __isInSubscriptionFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    return Zicl_SetResultBool(interp, self->inSubscription);
}
static int __isTracyEnabledFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
#ifdef TRACY_ENABLE
    return Zicl_SetResultBool(interp, true);
#else
    return Zicl_SetResultBool(interp, false);
#endif
}
static int __dbFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    char ret[100]; snprintf(ret, 100, "(Db*) %p", db);
    return Zicl_SetResultString(interp, ret, strlen(ret));
}
static int __threadIdFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    return Zicl_SetResultLong(interp, self->index);
}

static int __setFreshAtomicallyVersionOnKeyFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    const char* key = ziclShimString(&argv[1]);
    self->currentAtomicallyVersion =
        dbFreshAtomicallyVersionOnKey(db, key,
                                      matchRef(db, self->currentMatch));
    matchSetAtomicallyVersion(self->currentMatch, self->currentAtomicallyVersion);
    return ZICL_OK;
}
static int __currentAtomicallyVersionFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    if (self->currentAtomicallyVersion == NULL) {
        return Zicl_SetResultString(interp, "", -1);
    } else {
        char ret[100];
        snprintf(ret, 100, "(AtomicallyVersion*) %p",
                 self->currentAtomicallyVersion);
        return Zicl_SetResultString(interp, ret, strlen(ret));
    }
}

static int setpgrpFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 1);
    int ret = setpgrp();
    if (ret != -1) {
        return ZICL_OK;
    } else {
        return Zicl_SetErrorString(interp, strerror(errno), -1);
    }
}
static int exitFunc(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    assert(argc == 2);
    int rc = ZICL_OK;

    long exitCode; ZICL_TRY(Zicl_GetLong(interp, &argv[1], &exitCode), rc);

    // Use _exit to skip atexit handlers and avoid crashing threads
    // that are in non-cancellation-safe code (like dlopen).
    // Ignore SIGTRAP so pthread_cancel doesn't cause EXC_BREAKPOINT.
    fflush(stdout);
    fflush(stderr);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    signal(SIGTRAP, SIG_IGN);
    _exit(exitCode);

    return ZICL_OK;
}

// Sets up the `env` dict and redirection.
static void interpSetupEnv(Zicl_Interp *interp) {
    extern char **environ;

    Zicl_Dict *envDict = ziclNewDict(NULL, 0);
    defer { Zicl_ReleaseDict(envDict); }

    for (char **e = environ; *e != NULL; e++) {
        char *eq = strchr(*e, '=');
        if (eq == NULL) continue;

        ziclDictPut(envDict, ziclNewString(*e, eq - *e), ziclNewString(eq + 1, -1));
    }

    Zicl_SetVariableString(interp, "env", Zicl_BoxDict(envDict));
    Zicl_Value stdoutValue; Zicl_NewFileFromDescriptor(realStdout, &stdoutValue);
    Zicl_Value stderrValue; Zicl_NewFileFromDescriptor(realStderr, &stderrValue);
    Zicl_SetVariableString(interp, "realStdout", stdoutValue);
    Zicl_SetVariableString(interp, "realStderr", stderrValue);
}

void initSysmonInterp() {
    Zicl_InitThread();
    interp = Zicl_CreateInterp();
    interpSetupEnv(interp);
}

void __attribute__((noinline)) __attribute__((used)) magic_trace_stop_indicator() {
    asm volatile("" ::: "memory");
}
static int __magicTraceStopIndicatorFunc(Zicl_Interp* interp, int argc, Zicl_Shimmerable* argv) {
    magic_trace_stop_indicator();
    return ZICL_OK;
}

static void interpBoot() {
    Zicl_InitThread();
    interp = Zicl_CreateInterp();
    interpSetupEnv(interp);

    outputRedirectionInterpSetup(interp);

    Zicl_CreateCommand(interp, "Assert!", AssertFunc, "?term ...?", 0, -1);
    Zicl_CreateCommand(interp, "Retract!", RetractFunc, "?term ...?", 0, -1);
    Zicl_CreateCommand(
        interp, "HoldStatementGlobally!", HoldStatementGloballyFunc,
        "key version clause keepMs destructorCode sourceFileName sourceLineNumber",
        7, 7
    );

    Zicl_CreateCommand(interp, "NotifyImpl", NotifyFunc, "term ?term ...?", 0, -1);

    Zicl_CreateCommand(
        interp, "SayWithSource", SayWithSourceFunc,
        "keepMs version destructorCode sourceFileName sourceLineNumber clause",
        6, -1
    );
    Zicl_CreateCommand(interp, "Destructor", DestructorFunc, "destructor", 1, 1);

    Zicl_CreateCommand(interp, "QuerySimple!", QuerySimpleFunc, "isAtomically pattern ?pattern ...?", 2, -1);

    Zicl_CreateCommand(interp, "StatementAcquire!", StatementAcquireFunc, "statement", 1, 1);
    Zicl_CreateCommand(interp, "StatementRelease!", StatementReleaseFunc, "statement", 1, 1);
    Zicl_CreateCommand(interp, "__statementOfCurrentMatchSourceInfo", __statementOfCurrentMatchSourceInfoFunc, "", 0, 0);

    Zicl_CreateCommand(interp, "__scanVariable", __scanVariableFunc, "term", 1, 1);
    Zicl_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, "term", 1, 1);
    Zicl_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, "term", 1, 1);
    Zicl_CreateCommand(interp, "__currentMatchRef", __currentMatchRefFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "__statementIncompleteChildMatchesCount", __statementIncompleteChildMatchesCountFunc, "statement", 1, 1);
    Zicl_CreateCommand(interp, "__whenOfCurrentMatchIncompleteChildMatchesCount", __whenOfCurrentMatchIncompleteChildMatchesCountFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "__isInSubscription", __isInSubscriptionFunc, "", 0, 0);

    Zicl_CreateCommand(interp, "__isTracyEnabled", __isTracyEnabledFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "__blockRuntimeStats", __blockRuntimeStatsFunc, "", 0, 0);

    Zicl_CreateCommand(interp, "__db", __dbFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "__threadId", __threadIdFunc, "", 0, 0);

    Zicl_CreateCommand(interp, "__setFreshAtomicallyVersionOnKey", __setFreshAtomicallyVersionOnKeyFunc, "", 1, 1);
    Zicl_CreateCommand(interp, "__currentAtomicallyVersion", __currentAtomicallyVersionFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "__magicTraceStopIndicator", __magicTraceStopIndicatorFunc, "", 0, 0);

    Zicl_CreateCommand(interp, "setpgrp", setpgrpFunc, "", 0, 0);
    Zicl_CreateCommand(interp, "Exit!", exitFunc, "code", 1, 1);

    if (Zicl_EvalFile(interp, "prelude.tcl") != ZICL_OK) {
        Zicl_MakeErrorMessage(interp);
        FATAL("prelude: %s\n", ziclString(Zicl_GetResult(interp)));
    }
}
void eval(const char* code) {
    if (interp == NULL) { interpBoot(); }

    int error = Zicl_EvalValue(interp, ziclNewString(code, -1));
    if (error != ZICL_OK) {
        Zicl_MakeErrorMessage(interp);
        fprintf(stderr, "eval: (%s) -> (%s)\n", code, ziclString(Zicl_GetResult(interp)));
        Zicl_InterpDestroy(interp);
        exit(EXIT_FAILURE);
    }
}

//////////////////////////////////////////////////////////
// Evaluator
//////////////////////////////////////////////////////////

void workerExit();

// Looks up "this" in closure's captured scope (following ~parent links, so
// this reaches enclosing scopes too), falling back to "<unknown>" if there's
// no scope or no "this" in it. Owned; caller must Zicl_Release the result.
static Zicl_Value closureGetThis(Zicl_Closure* closure) {
    Zicl_Dict* scope = Zicl_ClosureGetScope(closure);
    if (scope != NULL) {
        Zicl_Shimmerable scopeShim = Zicl_NewShimmerable(Zicl_BoxDict(scope));
        defer { Zicl_ShimDiscardChanges(&scopeShim); }
        Zicl_OptionalValue out;
        if (Zicl_ShimDictGet(interp, &scopeShim, Zicl_InternStr("this"), &out) == ZICL_OK &&
            Zicl_IsSome(out)) {
            return Zicl_Borrow(Zicl_Unwrap(out));
        }
    }
    return Zicl_InternStr("<unknown>");
}

// Reports an error raised while running a block: prints it to stderr, and
// asserts (or, inside a subscription, holds) a "<this> has error <err> with
// info {-errorinfo <stack>}" statement, so other parts of a Folk program can
// react to it (see builtin-programs/errors.folk). This used to be a Tcl-level
// `try`/`on error` wrapper around applyBlock, reading $::this out of the
// merged environment; now that runBlock calls the closure directly, it's
// done here instead. thisValue is borrowed from the caller, which already
// had to look it up via closureGetThis to install output redirection.
static void runBlockReportError(Zicl_Value thisValue, const char* sourceFileName, int sourceLineNumber) {
    // Grab the raw message and structured stack before
    // Zicl_MakeErrorMessage consumes/reformats the interpreter's result.
    Zicl_Value errValue = Zicl_Borrow(Zicl_GetResult(interp));
    defer { Zicl_Release(errValue); }
    Zicl_Value stackTrace = Zicl_Borrow(Zicl_GetErrorStack(interp));
    defer { Zicl_Release(stackTrace); }

    Zicl_MakeErrorMessage(interp);
    fprintf(stderr, "\nError while running %s: %s\n",
            ziclString(thisValue), ziclString(Zicl_GetResult(interp)));

    Zicl_Value infoObjs[] = { Zicl_InternStr("-errorinfo"), stackTrace };
    Zicl_Value infoValue = Zicl_BoxDict(ziclNewDict(infoObjs, 2));
    defer { Zicl_Release(infoValue); }

    Zicl_Value clauseObjs[] = {
        thisValue, Zicl_InternStr("has"), Zicl_InternStr("error"), errValue,
        Zicl_InternStr("with"), Zicl_InternStr("info"), infoValue,
    };
    // Takes ownership of this list -- Say/HoldStatementGlobally below.
    Zicl_List* errorClause = ziclNewList(clauseObjs, 7);
    Zicl_MakeCrossthread(Zicl_BoxList(errorClause));

    if (self->inSubscription) {
        // Can't Say inside of a subscription, so Hold! instead (matching
        // the old Tcl behavior), keyed on `this` so a new error replaces
        // the previous one rather than accumulating duplicates.
        char suffix[256];
        snprintf(suffix, sizeof(suffix), "%s-error", ziclString(thisValue));
        Zicl_Value keyObjs[] = { thisValue, ziclNewString(suffix, -1) };
        Zicl_List* keyList = ziclNewList(keyObjs, 2);
        defer { Zicl_ReleaseList(keyList); }

        HoldStatementGlobally(ziclListString(keyList), -1, errorClause, 0, NULL,
                              sourceFileName, sourceLineNumber);
    } else {
        Say(errorClause, 0, NULL, NULL, sourceFileName, sourceLineNumber);
    }
}

static int runBlock(const Zicl_List* bodyPattern, const Zicl_List* toUnifyWith,
                    Zicl_Value closureObj, const char *sourceFileName, int sourceLineNumber) {
    // Figure out all the bound match variables by unifying when &
    // stmt:
    Environment* env = clauseUnify(bodyPattern, toUnifyWith);
    if (env == NULL) {
        // Unification failed.
        return ZICL_OK;
    }
    defer {
        for (int i = 0; i < env->nBindings; i++) Zicl_Release(env->bindings[i].value);
        free(env);
    }

    if (env->nBindings > 50) {
        fprintf(stderr, "runBlock: Too many bindings in env: %d\n",
                env->nBindings);
        return ZICL_OK;
    }

    int rc = ZICL_OK;
    Zicl_Closure* closure; ZICL_TRY(Zicl_GetClosure(interp, closureObj, &closure), rc);
    defer { Zicl_ReleaseClosure(closure); }

    // Install this block's output redirection before running it -- applyBlock
    // used to do this generically from the merged environment; now `this`
    // comes straight out of the closure's own captured scope.
    Zicl_Value thisValue = closureGetThis(closure);
    defer { Zicl_Release(thisValue); }
    fflush(stdout);
    installLocalStdoutAndStderrForProgram(ziclString(thisValue));

    // Rule: you should never be holding a lock while doing a Tcl
    // evaluation.
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
        defer { ___tracy_emit_zone_end(ctx); }
#endif

        int64_t t0 = timestamp_get(CLOCK_MONOTONIC);
        // argv[0] is the command-name slot Zicl_CallClosure expects (unused
        // for arity purposes), the actual bound values start at argv[1].
        Zicl_Shimmerable* bodyArgs = malloc(sizeof(Zicl_Shimmerable) * (env->nBindings + 1));
        defer { free(bodyArgs); }
        bodyArgs[0] = Zicl_NewShimmerable(thisValue);
        for (int i = 0; i < env->nBindings; i++) {
            bodyArgs[i + 1] = Zicl_NewShimmerable(env->bindings[i].value);
        }
        defer { for (int i = 0; i < env->nBindings + 1; i++) Zicl_ShimDiscardChanges(&bodyArgs[i]); }

        error = Zicl_CallClosure(interp, closure, env->nBindings + 1, bodyArgs);
        blockStatsUpdate(sourceFileName ? sourceFileName : "<unknown>", sourceLineNumber, timestamp_get(CLOCK_MONOTONIC) - t0);
    }

    if (error != ZICL_OK) {
        runBlockReportError(thisValue, sourceFileName, sourceLineNumber);
    }

    return error;
}

static void runWhenBlock(StatementRef whenRef, Zicl_List* whenPattern, StatementRef stmtRef) {
    // Dereference refs. if any fail, then skip this work item.
    // Exception: stmtRef can be a null ref if and only if whenPattern
    // is {}.
    Statement* when = NULL;
    Statement* stmt = NULL;
    defer { if (when) statementRelease(db, when); }
    defer { if (stmt) statementRelease(db, stmt); }

    when = statementAcquire(db, whenRef);
    if (when == NULL) return;

    if (!statementRefIsNull(stmtRef)) {
        stmt = statementAcquire(db, stmtRef);
        if (stmt == NULL) return;
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
                    whenAtomicallyVersion, ziclListString(statementClause(when)),
                    stmtAtomicallyVersion, ziclListString(statementClause(stmt)));
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
        return;
    }

    // make sure this is initialized
    self->inSubscription = false;

    // now that all the preconditions are met, we can get the parameters set
    // up for `runBlock`
    Zicl_List* whenClause = statementClause(when);
    Zicl_List* stmtClause = stmt == NULL ? whenPattern : statementClause(stmt);

    const Zicl_Value* whenClauseTerms = Zicl_ListItems(whenClause);
    size_t whenClauseLen = Zicl_ListLength(whenClause);
    assert(whenClauseLen >= 1);

    // when the time is /t/ /body/
    Zicl_Value bodyObj = whenClauseTerms[whenClauseLen - 1];

    runBlock(whenPattern, stmtClause, bodyObj,
        statementSourceFileName(when), statementSourceLineNumber(when));

    if (self->currentAtomicallyVersion != NULL) {
        dbAtomicallyVersionInflightDecr(db, self->currentAtomicallyVersion);
    }

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;
}

// Caller is responsible for freeing passed in clauses
static void runSubscribeBlock(StatementRef subscribeRef, const Zicl_List* subscribePattern,
                              const Zicl_List* notifyClause) {
    Statement* subscribeStmt = statementAcquire(db, subscribeRef);
    if (subscribeStmt == NULL) {  return; }
    defer { statementRelease(db, subscribeStmt); }

    self->currentMatch = NULL;
    self->inSubscription = true;

    Zicl_List* subscribeClause = statementClause(subscribeStmt);
    const Zicl_Value* subscribeClauseTerms = Zicl_ListItems(subscribeClause);
    size_t subscribeClauseLen = Zicl_ListLength(subscribeClause);
    assert(subscribeClauseLen >= 1);

    // key x was pressed
    // -> subscribe key x was pressed /lambda/
    Zicl_Value bodyObj = subscribeClauseTerms[subscribeClauseLen - 1];

    runBlock(subscribePattern, notifyClause, bodyObj,
        statementSourceFileName(subscribeStmt),
        statementSourceLineNumber(subscribeStmt));

    self->inSubscription = false;
}

// Copies the whenPattern Clause and all terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunWhenBlock(StatementRef whenRef, Zicl_List* whenPattern, StatementRef stmtRef) {
    // Make sure whenPattern is immutable, as it's about to become crossthread.
    // This also freezes it as a list.
    Zicl_MakeCrossthread(Zicl_BoxList(whenPattern));
    Zicl_Borrow(Zicl_BoxList(whenPattern)); // Take ownership.

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
static void pushRunSubscriptionBlock(StatementRef subscribeRef, Zicl_List* subscribePattern,
                              Zicl_List* notifyClause) {
    Zicl_MakeCrossthread(Zicl_BoxList(subscribePattern));
    Zicl_MakeCrossthread(Zicl_BoxList(notifyClause));
    Zicl_Borrow(Zicl_BoxList(subscribePattern));
    Zicl_Borrow(Zicl_BoxList(notifyClause));

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
// shouldn't be claimized. Returns new Zicl_List with refCount = 1
Zicl_List* claimizeClause(Zicl_List* clause) {
    Zicl_List* ret = ziclNewList(NULL, 0);

    int nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);
    if (nTerms >= 2) {
        if (ziclEquals(terms[1], Zicl_InternStr("claims")) ||
            ziclEquals(terms[1], Zicl_InternStr("wishes"))) {
            // Already a claim or wish, so we don't need to claimize it.
            Zicl_ReleaseList(ret);
            return NULL;
        }
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    ziclListAppend(ret, Zicl_InternStr("/someone/"));
    ziclListAppend(ret, Zicl_InternStr("claims"));
    for (int i = 0; i < nTerms; i++) ziclListAppend(ret, terms[i]);

    return ret;
}

// Returns new Zicl_List with refCount = 1
static Zicl_List* unclaimizeClause(Zicl_List* clause) {
    Zicl_List* ret = ziclNewList(NULL, 0);

    size_t nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);

    // Omar claims the time is 3
    //   -> the time is 3
    for (size_t i = 2; i < nTerms; i++) ziclListAppend(ret, terms[i]);

    return ret;
}

// Returns new Zicl_List with refCount = 1
static Zicl_List* whenizeClause(Zicl_List* clause) {
    // the time is /t/
    //   -> when the time is /t/ /__lambda/
    Zicl_List* ret = ziclNewList(NULL, 0);

    size_t nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);

    ziclListAppend(ret, Zicl_InternStr("when"));
    for (size_t i = 0; i < nTerms; i++) ziclListAppend(ret, terms[i]);
    ziclListAppend(ret, Zicl_InternStr("/__lambda/"));

    return ret;
}

// Returns new Zicl_List with refCount = 1
static Zicl_List* unwhenizeClause(Zicl_List* clause) {
    // when the time is /t/ /lambda/
    //   -> the time is /t/
    Zicl_List* ret = ziclNewList(NULL, 0);

    size_t nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);

    for (size_t i = 1; i < nTerms - 1; i++) ziclListAppend(ret, terms[i]);

    return ret;
}
static Zicl_List* subscriptionizeClause(Zicl_List* notifyClause) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/
    Zicl_List* ret = ziclNewList(NULL, 0);

    size_t nTerms = Zicl_ListLength(notifyClause);
    const Zicl_Value* terms = Zicl_ListItems(notifyClause);

    ziclListAppend(ret, Zicl_InternStr("subscribe"));
    for (size_t i = 0; i < nTerms; i++) ziclListAppend(ret, terms[i]);
    ziclListAppend(ret, Zicl_InternStr("/__lambda/"));

    return ret;
}
// currently the same as unwhenizeClause, but semantically different
static Zicl_List* unsubscriptionizeClause(Zicl_List* subscribeClause) {
    // subscribe the time is /t/ /lambda/
    //        -> the time is /t/
    Zicl_List* ret = ziclNewList(NULL, 0);

    size_t nTerms = Zicl_ListLength(subscribeClause);
    const Zicl_Value* terms = Zicl_ListItems(subscribeClause);

    for (size_t i = 1; i < nTerms - 1; i++) ziclListAppend(ret, terms[i]);

    return ret;
}

// React to the addition of a new statement: fire any pertinent
// existing Whens & if the new statement is a When, then fire it with
// respect to any pertinent existing statements. 
static void reactToNewStatement(StatementRef ref) {
    // This is just to ensure clause validity.
    Statement* stmt = statementAcquire(db, ref);
    if (stmt == NULL) { return; }
    defer { statementRelease(db, stmt); }

    Zicl_List* clause = statementClause(stmt);
    assert(clause != NULL);

    size_t nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);

    if (nTerms >= 1 && ziclEquals(terms[0], Zicl_InternStr("subscribe"))) {
        // nothing to do, as subscribe is handled when events are
        // fired
        return;
    }

    if (nTerms >= 1 && ziclEquals(terms[0], Zicl_InternStr("when"))) {
        // Find the query pattern of the when:
        Zicl_List* pattern = unwhenizeClause(clause);
        defer { Zicl_ReleaseList(pattern); }

        if (Zicl_ListLength(pattern) == 0) {
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
            defer { free(existingMatchingStatements); }
            for (size_t i = 0; i < existingMatchingStatements->nResults; i++) {
                pushRunWhenBlock(
                    ref,
                    pattern,
                    existingMatchingStatements->results[i]
                );
            }

            Zicl_List* claimizedPattern = claimizeClause(pattern);
            defer { if (claimizedPattern) Zicl_ReleaseList(claimizedPattern); }
            if (claimizedPattern) {
                ResultSet* claimizedExistingMatchingStatements = dbQuery(db, claimizedPattern);
                defer { free(claimizedExistingMatchingStatements); }
                for (size_t i = 0; i < claimizedExistingMatchingStatements->nResults; i++) {
                    pushRunWhenBlock(
                        ref,
                        claimizedPattern,
                        claimizedExistingMatchingStatements->results[i]
                    );
                }
            }
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
        //   -> when the time is 3 /__lambda/
        Zicl_List* whenizedClause = whenizeClause(clause);
        defer { Zicl_ReleaseList(whenizedClause); }
        ResultSet* existingReactingWhens = dbQuery(db, whenizedClause);
        defer { free(existingReactingWhens); }
        /* trace("Adding stmt: existing reacting whens (%d)", */
        /*       existingReactingWhens->nResults); */
        for (size_t i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/
            //   -> the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            defer { if (when) statementRelease(db, when); }
            if (when) {
                Zicl_List* whenPattern = unwhenizeClause(statementClause(when));
                defer { Zicl_ReleaseList(whenPattern); }

                pushRunWhenBlock(
                    whenRef,
                    whenPattern,
                    ref
                );
            }
        }
    }

    if (nTerms >= 2 && ziclEquals(terms[1], Zicl_InternStr("claims"))) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/
        Zicl_List* unclaimizedClause = unclaimizeClause(clause);
        Zicl_List* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        defer { free(existingReactingWhens); }
        Zicl_ReleaseList(unclaimizedClause);
        Zicl_ReleaseList(whenizedUnclaimizedClause);

        for (size_t i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            defer { if (when) statementRelease(db, when); }
            if (when) {
                Zicl_List* unwhenizedWhenPattern = unwhenizeClause(statementClause(when));
                defer { Zicl_ReleaseList(unwhenizedWhenPattern); }
                Zicl_List* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);
                defer { Zicl_ReleaseList(claimizedUnwhenizedWhenPattern); }

                pushRunWhenBlock(
                    whenRef,
                    // takes ownership
                    claimizedUnwhenizedWhenPattern,
                    ref
                );
            }
        }
    }
}

static void Notify(Zicl_List* toNotify) {
    // key x was pressed
    // -> subscribe key x was pressed /lambda/
    Zicl_List* clauseQuery = subscriptionizeClause(toNotify);
    defer { Zicl_ReleaseList(clauseQuery); }
    ResultSet* rs = dbQuery(db, clauseQuery);
    defer { free(rs); }

    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* subscription = statementAcquire(db, rs->results[i]);
        if (subscription == NULL) { continue; }
        defer { statementRelease(db, subscription); }

        Zicl_List* subscriptionPattern = unsubscriptionizeClause(statementClause(subscription));
        defer { Zicl_ReleaseList(subscriptionPattern); }
        pushRunSubscriptionBlock(rs->results[i], subscriptionPattern, toNotify);
    }
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

        // incremented when pushed to the queue
        Zicl_ReleaseList(item.assert.clause);
        free(item.assert.sourceFileName);

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */
        dbRetractStatements(db, item.retract.pattern);

        // incremented when pushed to the queue
        Zicl_ReleaseList(item.retract.pattern);

    } else if (item.op == RUN_WHEN) {
        /* printf("  when: %d:%d; stmt: %d:%d\n", item.run.when.idx, item.run.when.gen, */
        /*        item.run.stmt.idx, item.run.stmt.gen); */
        runWhenBlock(item.runWhen.when, item.runWhen.whenPattern, item.runWhen.stmt);
        Zicl_ReleaseList(item.runWhen.whenPattern);

    } else if (item.op == RUN_SUBSCRIBE) {
        runSubscribeBlock(item.runSubscribe.subscribeRef, item.runSubscribe.subscribePattern,
                          item.runSubscribe.notifyClause);
        Zicl_ReleaseList(item.runSubscribe.subscribePattern);
        Zicl_ReleaseList(item.runSubscribe.notifyClause);

    } else if (item.op == EVAL) {
        // Used for destructors.
        char* code = item.eval.code;
        defer { free(code); }

        int error = Zicl_Eval(interp, code);
        if (error == ZICL_EXIT) {
            workerExit();
        } else if (error != ZICL_OK) {
            Zicl_MakeErrorMessage(interp);
            fprintf(stderr, "destructorHelper: (%s) -> (%s)\n",
                    code, ziclString(Zicl_GetResult(interp)));
        }

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
                 ziclListString(item.assert.clause));

    } else if (item.op == RETRACT) {
        snprintf(buf, bufsz, "Retract (%.100s)",
                 ziclListString(item.retract.pattern));

    } else if (item.op == RUN_WHEN) {
        Statement* when = statementAcquire(db, item.runWhen.when);
        Statement* stmt = statementAcquire(db, item.runWhen.stmt);
        snprintf(buf, bufsz, "Run when(%.100s) pattern(%.100s) stmt(%.100s)",
                 when != NULL ? ziclListString(statementClause(when)) : "NULL",
                 ziclListString(item.runWhen.whenPattern),
                 stmt != NULL ? ziclListString(statementClause(stmt)) : "NULL");
        if (when) statementRelease(db, when);
        if (stmt) statementRelease(db, stmt);

    } else if (item.op == RUN_SUBSCRIBE) {
        Statement* subscribe = statementAcquire(db, item.runSubscribe.subscribeRef);
        snprintf(buf, bufsz, "Run subscribe(%.100s) pattern(%.100s) stmt(%.100s)",
                 subscribe != NULL ? ziclListString(statementClause(subscribe)) : "NULL",
                 ziclListString(item.runSubscribe.subscribePattern),
                 ziclListString(item.runSubscribe.notifyClause));
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
        Zicl_ArenaSnapshot snapshot = Zicl_LocalArenaSnapshot();
        defer { Zicl_LocalArenaRewind(snapshot); }

        schedtick++;

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

    // Needed for Zicl panic messages to show up.
    installLocalStdoutAndStderr(realStdout, realStderr);

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
    Zicl_InterpDestroy(interp);
    Zicl_DeinitThread();
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
    Zicl_InitGlobals(NULL);

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
             "fn run {} { set this {%s}; source {%s} }; run",
             bootFile, bootFile);
    eval(code);

    workerLoop();
}
