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

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#define JIM_EMBEDDED
#include <jim.h>

#include "vendor/c11-queues/mpmc_queue.h"

#include "epoch.h"
#include "db.h"
#include "common.h"
#include "sysmon.h"
#include "cache.h"

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
        fprintf(stderr, "globalWorkQueuePush: failed\n");
        while (mpmc_queue_available(&globalWorkQueue)) {
            WorkQueueItem* x;
            mpmc_queue_pull(&globalWorkQueue, (void **)&x);
            char s[1000]; traceItem(s, 1000, *x);
            fprintf(stderr, "(%.200s)\n", s);
        }
        exit(1);
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

// Pushes to either self or the global workqueue, depending on how
// long the current work item has been running.
void appropriateWorkQueuePush(WorkQueueItem item) {
    if (self) {
        int64_t now = timestamp_get(self->clockid);
        if (self->currentItemStartTimestamp == 0 ||
            now - self->currentItemStartTimestamp < 1000000) {
            // The current worker is responsive (hasn't been running that
            // long). Push to its queue.
            workQueuePush(self->workQueue, item);
            return;
        }
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

__thread Cache* cache = NULL;

Db* db;

// Appends a string to a list. List be non-shared
static void jimAppendString(Jim_Interp* interp, Jim_Obj* listPtr, const char* str) {
    Jim_ListAppendElement(interp, listPtr, Jim_NewStringObj(interp, str, -1));
}

static Clause* jimObjsToTrieClause(int objc, Jim_Obj *const *objv) {
    Clause* clause = malloc(SIZEOF_CLAUSE(objc));
    clause->nTerms = objc;

    const char* str;
    char* newStr;
    int len;
    for (int i = 0; i < objc; i++) {
        // Jim "strings" are not guaranteed to be null terminated,
        // as they're effectively byte arrays. We'll go ahead and
        // terminate it ourselves in the case that this object is
        // not terminated.

        str = Jim_GetString(interp, objv[i], &len);
        newStr = malloc(len + 1); // +1 for null cap
        memcpy(newStr, str, len);
        newStr[len] = 0x00;

        clause->terms[i] = newStr;
    }
    return clause;
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
                    clauseToString(jimClauseToTrieClause(interp, a)),
                    clauseToString(jimClauseToTrieClause(interp, b)));
            return NULL;
        }
    }
    return env;
}

// Assert! the time is 3
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_Obj* jimClause = Jim_NewListObj(interp, argv + 1, argc - 1);

    Jim_Obj* scriptObj = interp->evalFrame->scriptObj;
    const char* sourceFileName;
    int sourceLineNumber;
    if (Jim_ScriptGetSourceFileName(interp, scriptObj, &sourceFileName) != JIM_OK) {
        sourceFileName = "<unknown>";
    }
    if (Jim_ScriptGetSourceLineNumber(interp, scriptObj, &sourceLineNumber) != JIM_OK) {
        sourceLineNumber = -1;
    }

    Jim_MakeImmutable(interp, jimClause);
    Jim_IncrRefCount(jimClause);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = ASSERT,
       .assert = {
           .clause = jimClause,
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
                                          Jim_Obj *jimClause, long keepMs, const char *destructorCode,
                                          const char *sourceFileName, int sourceLineNumber) {
/* #ifdef TRACY_ENABLE */
/*     char *s = clauseToString(clause); */
/*     TracyCMessageFmt("hold: %.200s", s); free(s); */
/* #endif */

    StatementRef oldRef; Statement* newStmt;

    newStmt = dbHoldStatement(db, interp, key, version,
                              jimClause, keepMs,
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
                           Jim_Obj *jimClause, long keepMs, const char *destructorCode,
                           const char *sourceFileName, int sourceLineNumber) {
    Statement* stmt = HoldStatementGloballyAcquiring(key, version,
                                                     jimClause, keepMs, destructorCode,
                                                     sourceFileName, sourceLineNumber);
    if (stmt != NULL) {
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
    Jim_Obj *jimClause = argv[3];
    long keepMs; Jim_GetLong(interp, argv[4], &keepMs);
    int destructorCodeLen;
    const char* destructorCode = Jim_GetString(interp, argv[5], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    HoldStatementGlobally(key, version,
                          jimClause, keepMs, destructorCode,
                          sourceFileName, sourceLineNumber);

    return (JIM_OK);
}


static StatementRef Say(Jim_Obj* jimClause, long keepMs, const char *destructorCode,
                        const char *sourceFileName, int sourceLineNumber) {
    MatchRef parent;
    if (self->currentMatch) {
        parent = matchRef(db, self->currentMatch);
    } else {
        parent = MATCH_REF_NULL;
        const char *s = Jim_String(interp, jimClause);
        fprintf(stderr, "Warning: Creating unparented Say (%.100s)\n", s);
    }

    Statement* stmt;
    stmt = dbInsertOrReuseStatement(db, interp, jimClause, keepMs,
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
        statementRelease(db, stmt);

        reactToNewStatement(ref);
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
    assert(argc >= 6);
    Jim_Obj* jimClause = Jim_NewListObj(interp, argv + 5, argc - 5);

    const char* sourceFileName;
    long sourceLineNumber;
    sourceFileName = Jim_String(interp, argv[1]);
    if (sourceFileName == NULL) { return JIM_ERR; }
    if (Jim_GetLong(interp, argv[2], &sourceLineNumber) == JIM_ERR) {
        return JIM_ERR;
    }

    long keepMs;
    if (Jim_GetLong(interp, argv[3], &keepMs) == JIM_ERR) {
        return JIM_ERR;
    }

    int destructorCodeLen;
    const char* destructorCode = Jim_GetString(interp, argv[4], &destructorCodeLen);
    if (destructorCodeLen == 0) {
        destructorCode = NULL;
    }

    if (self->inSubscription) {
        Jim_SetResultString(interp, "Cannot call Say within Subscribe", -1);
        return JIM_ERR;
    }

    Say(clause, keepMs, destructorCode,
        sourceFileName, (int) sourceLineNumber);
    return JIM_OK;
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

static void Notify(Clause* toNotify);
static int NotifyFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc >= 2);

    Clause* toNotify = jimObjsToClauseWithCaching(argc - 1, argv + 1);
    Notify(toNotify);

    clauseFree(toNotify);
    return JIM_OK;
}

Jim_Obj* QuerySimple(Jim_Obj* pattern) {
    // pattern can be on the temp list, as its child elements
    // can outlast the temp list being cleared
    pattern = Jim_DupIfImmutAndWrongRep(interp, pattern, Jim_ListType(), JIM_TEMP_LIST);
    // make sure it has a list rep
    Jim_ListLength(interp, pattern);

    Clause* tempClause = jimClauseToTrieClause(interp, pattern);
    ResultSet* rs = dbQuery(db, tempClause);
    clauseFree(tempClause);

    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);
    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* result = statementAcquire(db, rs->results[i]);
        if (result == NULL) { continue; }

        Environment* env = clauseUnify(pattern, statementJimClause(result));
        assert(env != NULL);
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
    assert(argc >= 2);

    Jim_Obj* pattern = Jim_NewListObj(interp, argv + 1, argc - 1);
#ifdef TRACY_ENABLE
    TracyCMessageFmt("query: %.200s", Jim_String(interp, pattern));
#endif

    Jim_Obj *retObj = QuerySimple(pattern);
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
static int __isWhenOfCurrentMatchAlreadyRunningFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
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

    MatchRef currentMatchRef = matchRef(db, self->currentMatch);
    Jim_SetResultBool(interp, statementHasOtherIncompleteChildMatch(db, when, currentMatchRef));

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

    // Stop and await all other threads. If we just do a normal exit,
    // then other threads are likely to crash the program first by
    // trying to access freed stuff.
    for (int i = 0; i < threadCount; i++) {
        if (threads[i].tid == 0) { continue; }
        if (&threads[i] == self) { continue; }

        char buf[10000]; traceItem(buf, sizeof(buf), threads[i].currentItem);

        pthread_kill(threads[i].pthread, SIGUSR1);
        pthread_cancel(threads[i].pthread);
    }
    for (int i = 0; i < threadCount; i++) {
        if (threads[i].tid == 0) { continue; }
        if (&threads[i] == self) { continue; }
        pthread_join(threads[i].pthread, NULL);
    }

    exit(exitCode);

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
    cache = cacheNew();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    Jim_CreateCommand(interp, "Assert!", AssertFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Retract!", RetractFunc, NULL, NULL);
    Jim_CreateCommand(interp, "HoldStatementGlobally!", HoldStatementGloballyFunc, NULL, NULL);

    Jim_CreateCommand(interp, "NotifyImpl", NotifyFunc, NULL, NULL);

    Jim_CreateCommand(interp, "SayWithSource", SayWithSourceFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Destructor", DestructorFunc, NULL, NULL);

    Jim_CreateCommand(interp, "QuerySimple!", QuerySimpleFunc, NULL, NULL);

    Jim_CreateCommand(interp, "StatementAcquire!", StatementAcquireFunc, NULL, NULL);
    Jim_CreateCommand(interp, "StatementRelease!", StatementReleaseFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__scanVariable", __scanVariableFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__currentMatchRef", __currentMatchRefFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__isWhenOfCurrentMatchAlreadyRunning", __isWhenOfCurrentMatchAlreadyRunningFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__isInSubscription", __isInSubscriptionFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__isTracyEnabled", __isTracyEnabledFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__db", __dbFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__threadId", __threadIdFunc, NULL, NULL);

    Jim_CreateCommand(interp, "setpgrp", setpgrpFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Exit!", exitFunc, NULL, NULL);

    if (Jim_EvalFile(interp, "prelude.tcl") == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "prelude: %s\n", Jim_String(interp, Jim_GetResult(interp)));
        exit(1);
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
static void runBlock(Jim_Obj* bodyPattern, Jim_Obj* toUnifyWith, Jim_Obj* bodyObj,
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
                          Jim_NewStringObj(interp, statementSourceFileName(when), -1),
                          statementSourceLineNumber(when));
    }

    {
        // Figure out all the bound match variables by unifying when &
        // stmt:
        Environment* env = clauseUnify(interp, bodyPattern, toUnifyWith);
        assert(env != NULL);

        if (env->nBindings > 50) {
            fprintf(stderr, "runBlock: Too many bindings in env: %d\n",
                    env->nBindings);
            return;
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
        const char *source = statementSourceFileName(when);
        char name[1000];
        int namesz = snprintf(name, 1000, "%s:%d",
                              source, statementSourceLineNumber(when));
        uint64_t srcloc = ___tracy_alloc_srcloc(statementSourceLineNumber(when),
                                               source, strlen(source),
                                               name, namesz,
                                               0);
        TracyCZoneCtx ctx = ___tracy_emit_zone_begin_alloc(srcloc, 1);
#endif

        Jim_Obj *objv[] = {
            // TODO: pool this string?
            Jim_NewStringObj(interp, "evaluateWhenBlock", -1),
            bodyObj,
            combinedEnvStack
        };
        error = Jim_EvalObjVector(interp, sizeof(objv)/sizeof(objv[0]), objv);

#ifdef TRACY_ENABLE
        ___tracy_emit_zone_end(ctx);
#endif
    }
    interp->signal_level--;

    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        const char *errorMessage = Jim_GetString(Jim_GetResult(interp), NULL);
        fprintf(stderr, "Fatal (uncaught) error running When (%.100s):\n  %s\n",
                Jim_String(interp, bodyObj), errorMessage);
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);

    } else if (error == JIM_SIGNAL) {
        // FIXME: I think this is the only signal handler path that
        // actually runs mostly.
        interp->sigmask = 0;
        workerExit();
    }

    Jim_DecrRefCount(combinedEnvStack);
}

static void runWhenBlock(StatementRef whenRef, Clause* whenPattern, StatementRef stmtRef) {
    // Dereference refs. if any fail, then skip this work item.
    // Exception: stmtRef can be a null ref if and only if whenPattern
    // is {}.
    Statement* when = NULL;
    Statement* stmt = NULL;
    when = statementAcquire(db, whenRef);
    if (when == NULL) {
        Jim_DecrRefCount(whenPattern);
        return;
    }

    if (!statementRefIsNull(stmtRef)) {
        stmt = statementAcquire(db, stmtRef);
        if (stmt == NULL) {
            statementRelease(db, when);
            Jim_DecrRefCount(whenPattern);
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
        self->currentMatch = dbInsertMatch(db, 2, parents, self->index);
    } else {
        StatementRef parents[] = { whenRef };
        self->currentMatch = dbInsertMatch(db, 1, parents, self->index);
    }

    // check if match failed to be created
    if (!self->currentMatch) {
        // A parent is gone. Abort.
        statementRelease(db, when);
        if (stmt != NULL) {
            statementRelease(db, stmt);
        }
        goto jimObjDecr;
    }

    // make sure this is initialized
    self->inSubscription = false;

    // now that all the preconditions are met, we can get the parameters set
    // up for `runBlock`
    Jim_Obj* whenClause = statementJimClause(when);
    Jim_Obj* stmtClause = stmt == NULL ? whenPattern : statementJimClause(stmt);

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

    statementRelease(db, when);
    if (stmt != NULL) { statementRelease(db, stmt); }

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;

jimObjDecr:
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

    Jim_Obj* subscribeClause = statementJimClause(subscribeStmt);
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
static void pushRunWhenBlock(StatementRef when, Jim_Obj* whenPattern, StatementRef stmt) {
    // make sure whenPattern is immutable, as it's about to become shared
    Jim_MakeImmutable(interp, whenPattern);
    Jim_IncrRefCount(whenPattern);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RUN_WHEN,
       .runWhen = { .when = when, .whenPattern = whenPattern, .stmt = stmt }
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

// Prepends `/someone/ claims` to `clause`. Returns NULL if `clause`
// shouldn't be claimized. Returns new Jim_Obj with refCount = 0
Jim_Obj* claimizeClause(Jim_Obj* jimClause) {
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(jimClause));
    int nTerms = Jim_ListLength(interp, jimClause);

    const char* firstTerm = Jim_String(interp, Jim_ListGetIndex(interp, jimClause, 1));
    if (nTerms >= 2 &&
        (strcmp(firstTerm, "claims") == 0 ||
         strcmp(firstTerm, "wishes") == 0)) {
        Jim_FreeNewObj(ret);
        return NULL;
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    jimAppendString(interp, ret, "/someone/");
    jimAppendString(interp, ret, "claims");

    for (int i = 0; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, jimClause, i));
    }

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* unclaimizeClause(Jim_Obj* jimClause) {
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(jimClause));
    size_t nTerms = Jim_ListLength(interp, jimClause);

    // Omar claims the time is 3
    //   -> the time is 3
    for (size_t i = 2; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, jimClause, i));
    }

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* whenizeClause(Jim_Obj* jimClause) {
    // the time is /t/
    //   -> when the time is /t/ /__lambda/ with environment /__env/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(jimClause));
    size_t nTerms = Jim_ListLength(interp, jimClause);

    jimAppendString(interp, ret, "when");
    for (int i = 0; i < nTerms; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, jimClause, i));
    }
    jimAppendString(interp, ret, "/__lambda/");
    jimAppendString(interp, ret, "with");
    jimAppendString(interp, ret, "environment");
    jimAppendString(interp, ret, "/__env/");

    return ret;
}

// Returns new Jim_Obj with refCount = 0
static Jim_Obj* unwhenizeClause(Jim_Obj* jimClause) {
    // when the time is /t/ /lambda/ with environment /env/
    //   -> the time is /t/
    Jim_Obj* ret = Jim_NewListObj(interp, NULL, 0);

    assert(Jim_IsList(jimClause));
    size_t nTerms = Jim_ListLength(interp, jimClause);

    for (int i = 1; i < nTerms - 4; i++) {
        Jim_ListAppendElement(interp, ret, Jim_ListGetIndex(interp, jimClause, i));
    }

    return ret;
}
static Jim_Obj* whenizeClause(Jim_Obj* notifyClause) {
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
    Jim_Obj* jimClause = statementJimClause(stmt);
    assert(jimClause != NULL);

    Jim_Obj* firstTerm = Jim_ListGetIndex(interp, jimClause, 0);
    if (firstTerm != NULL && strcmp(Jim_String(interp, firstTerm), "subscribe") == 0) {
        // nothing to do, as subscribe is handled when events are
        // fired
        statementRelease(db, stmt);
        return;
    }

    if (firstTerm != NULL && strcmp(Jim_String(interp, firstTerm), "when") == 0) {
        // Find the query pattern of the when:
        Jim_Obj* pattern = unwhenizeClause(jimClause);
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
            Clause* triePattern = jimClauseToTrieClause(interp, pattern);
            ResultSet* existingMatchingStatements = dbQuery(db, triePattern);
            for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                pushRunWhenBlock(
                    ref,
                    pattern,
                    existingMatchingStatements->results[i]
                );
            }
            free(existingMatchingStatements);
            clauseFree(triePattern);

            Jim_Obj* claimizedPattern = claimizeClause(pattern);
            if (claimizedPattern) {
                Jim_IncrRefCount(claimizedPattern);

                Clause* claimizedTriePattern = jimClauseToTrieClause(interp, claimizedPattern);
                existingMatchingStatements = dbQuery(db, claimizedTriePattern);
                for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                    pushRunWhenBlock(
                        ref,
                        claimizedPattern,
                        existingMatchingStatements->results[i]
                    );
                }
                free(existingMatchingStatements);
                clauseFree(claimizedTriePattern);
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
        Jim_Obj* whenizedJimClause = whenizeClause(jimClause);
        Clause* whenizedTrieClause = jimClauseToTrieClause(interp, whenizedJimClause);
        ResultSet* existingReactingWhens = dbQuery(db, whenizedTrieClause);
        /* trace("Adding stmt: existing reacting whens (%d)", */
        /*       existingReactingWhens->nResults); */
        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Jim_Obj* whenPattern = unwhenizeClause(statementJimClause(when));
                statementRelease(db, when);

                pushRunWhenBlock(
                    whenRef,
                    whenPattern,
                    ref
                );
            }
        }
        free(existingReactingWhens);

        Jim_FreeNewObj(whenizedJimClause);
        clauseFree(whenizedTrieClause);
    }

    Jim_Obj* secondTerm = Jim_ListGetIndex(interp, jimClause, 1);
    if (secondTerm != NULL && strcmp(Jim_String(interp, secondTerm), "claims") == 0) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Jim_Obj* unclaimizedClause = unclaimizeClause(jimClause);
        Jim_Obj* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);
        Clause* whenizedUnclaimizedTrieClause =
            jimClauseToTrieClause(interp, whenizedUnclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedTrieClause);
        Jim_FreeNewObj(unclaimizedClause);
        Jim_FreeNewObj(whenizedUnclaimizedClause);
        clauseFree(whenizedUnclaimizedTrieClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Jim_Obj* unwhenizedWhenPattern = unwhenizeClause(statementJimClause(when));
                Jim_Obj* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);
                statementRelease(db, when);

                pushRunWhenBlock(
                    whenRef,
                    // takes ownership
                    claimizedUnwhenizedWhenPattern,
                    ref
                );

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
    Jim_Obj* query = subscriptionizeClause(toNotify);
    ResultSet* rs = dbQuery(db, query);

    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* subscription = statementAcquire(db, rs->results[i]);
        if (subscription == NULL) { continue; }

        Jim_Obj* subscriptionPattern = unsubscriptionizeClause(statementJimClause(subscription));

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
        fprintf(stderr, "workerRun: Unknown item type\n");
        exit(1);
    }
#endif

    self->currentItemStartTimestamp = timestamp_get(self->clockid);

    mutexLock(&self->currentItemMutex);
    self->currentItem = item;
    mutexUnlock(&self->currentItemMutex);

    if (item.op == ASSERT) {
        /* printf("Assert (%s)\n", clauseToString(item.assert.clause)); */

        Statement* stmt;
        stmt = dbInsertOrReuseStatement(db, interp, item.assert.clause, 0,
                                        item.assert.sourceFileName,
                                       item.assert.sourceLineNumber,
                                        MATCH_REF_NULL, NULL);
        if (stmt != NULL) {
            StatementRef ref = statementRef(db, stmt);
            statementRelease(db, stmt);

            reactToNewStatement(ref);
        }

        // incremented when pushed to the queue
        Jim_DecrRefCount(item.assert.clause);
        free(item.assert.sourceFileName);

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */
        Clause *triePattern = jimClauseToTrieClause(interp, item.retract.pattern);
        dbRetractStatements(db, triePattern);

        // incremented when pushed to the queue
        Jim_DecrRefCount(item.retract.pattern);
        clauseFree(triePattern);

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
        fprintf(stderr, "workerRun: Unknown work item op: %d\n",
                item.op);
        exit(1);
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
        Clause* trieClause = jimClauseToTrieClause(interp, item.assert.clause);
        snprintf(buf, bufsz, "Assert (%.100s)", clauseToString(trieClause));
        clauseFree(trieClause);
    } else if (item.op == RETRACT) {
        Clause* triePattern = jimClauseToTrieClause(interp, item.retract.pattern);
        snprintf(buf, bufsz, "Retract (%.100s)", clauseToString(triePattern));
        clauseFree(triePattern);
    } else if (item.op == RUN_WHEN) {
        Statement* when = statementUnsafeGet(db, item.runWhen.when);
        Statement* stmt = statementUnsafeGet(db, item.runWhen.stmt);
        Clause* trieWhenPattern = jimClauseToTrieClause(interp, item.runWhen.whenPattern);
        snprintf(buf, bufsz, "Run when(%.100s) pattern(%.100s) stmt(%.100s)",
                 when != NULL ? Jim_String(interp, statementJimClause(when)) : "NULL",
                 clauseToString(trieWhenPattern),
                 stmt != NULL ? Jim_String(interp, statementJimClause(stmt)) : "NULL");
        clauseFree(trieWhenPattern);
    } else if (item.op == RUN_SUBSCRIBE) {
        Statement* subscribe = statementUnsafeGet(db, item.runSubscribe.subscribeRef);
        Clause* trieSubscribePattern = jimClauseToTrieClause(interp, item.runSubscribe.subscribePattern);
        Clause* trieNotifyClause = jimClauseToTrieClause(interp, item.runSubscribe.notifyClause);
        snprintf(buf, bufsz, "Run subscribe(%.100s) pattern(%.100s) stmt(%.100s)",
                 subscribe != NULL ? clauseToString(statementClause(subscribe)) : "NULL",
                 clauseToString(trieSubscribePattern),
                 clauseToString(trieNotifyClause));
        clauseFree(trieSubscribePattern);
        clauseFree(trieNotifyClause);
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

    // TODO: Clear everything else out?
    self->tid = 0;
    Jim_FreeInterp(interp);

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
        fprintf(stderr, "folk: workerMain: exceeded THREADS_MAX\n");
        exit(1);
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

void workerReactivateOrSpawn(int64_t msSinceBoot) {
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
    if (nLivingThreads > 20) {
        if (msSinceBoot > 10000) {
            // (Don't print a warning before 10 seconds have elapsed
            // since boot, because we expect to have to do a lot of
            // work at startup, and we don't want to spam stderr.)
            fprintf(stderr, "folk: workerReactivateOrSpawn: "
                    "Not spawning new thread; too many already\n");
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
    fprintf(stderr, "workerSpawn\n");
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

    // Set up database.
    db = dbNew();

    workQueueInit();

    globalWorkQueueInit();

    {
        // Spawn the sysmon thread, which isn't managed the same way
        // as worker threads, and which doesn't run a Folk
        // interpreter. It's just pure C. It's also guaranteed(?) to
        // not run more than every few milliseconds, so it's ok to let
        // it run on the free core.
        sysmonInit();
        pthread_t sysmonTh;
        pthread_create(&sysmonTh, NULL, sysmonMain, NULL);
    }

    /* struct sched_param param; */
    /* param.sched_priority = 1; */
    /* pthread_setschedparam(pthread_self(), SCHED_FIFO, &param); */

#ifdef __linux__
    // Count CPUs so we can set up the thread pool to align with the
    // available cores.
    cpu_set_t cs; CPU_ZERO(&cs);
    sched_getaffinity(0, sizeof(cs), &cs);
    int cpuCount = CPU_COUNT(&cs);
    printf("main: CPU_COUNT = %d\n", cpuCount);
    assert(cpuCount >= 2);

    // Disable CPU 0 entirely; we will leave it to Linux. Goal:
    // exclude one CPU from Folk, so that Linux can still accept ssh
    // connections and stuff like that if Folk goes off the rails.
    CPU_CLR(0, &cs);
    sched_setaffinity(0, sizeof(cs), &cs);
    int cpuUsableCount = cpuCount - 1;
#else
    // HACK: for macOS.
    int cpuUsableCount = 8;
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
