#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>
#include <stdatomic.h>
#include <inttypes.h>

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
#include "trace.h"

ThreadControlBlock threads[THREADS_MAX];
int _Atomic threadCount;
__thread ThreadControlBlock* self;
// helper function to get self from LLDB:
ThreadControlBlock* getSelf() { return self; }

struct mpmc_queue globalWorkQueue;
_Atomic int globalWorkQueueSize;
void globalWorkQueueInit() {
    mpmc_queue_init(&globalWorkQueue, 1024, &memtype_heap);
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

__thread Jim_Interp* interp = NULL;

Db* db;

char traceHead[TRACE_HEAD_COUNT][TRACE_ENTRY_SIZE];
char traceTail[TRACE_TAIL_COUNT][TRACE_ENTRY_SIZE];
int _Atomic traceNextIdx = 0;

static Clause* jimArgsToClause(int argc, Jim_Obj *const *argv) {
    Clause* clause = malloc(SIZEOF_CLAUSE(argc - 1));
    clause->nTerms = argc - 1;
    for (int i = 1; i < argc; i++) {
        clause->terms[i - 1] = strdup(Jim_GetString(argv[i], NULL));
    }
    return clause;
}
static Clause* jimObjToClause(Jim_Interp* interp, Jim_Obj* obj) {
    int objc = Jim_ListLength(interp, obj);
    Clause* clause = malloc(SIZEOF_CLAUSE(objc));
    clause->nTerms = objc;
    for (int i = 0; i < objc; i++) {
        clause->terms[i] = strdup(Jim_GetString(Jim_ListGetIndex(interp, obj, i), NULL));
    }
    return clause;
}
static Jim_Obj* termsToJimObj(Jim_Interp* interp, int nTerms, char* terms[]) {
    Jim_Obj* termObjs[nTerms];
    for (int i = 0; i < nTerms; i++) {
        termObjs[i] = Jim_NewStringObj(interp, terms[i], -1);
    }
    return Jim_NewListObj(interp, termObjs, nTerms);
}

typedef struct EnvironmentBinding {
    char name[100];
    Jim_Obj* value;
} EnvironmentBinding;
typedef struct Environment {
    int nBindings;
    EnvironmentBinding bindings[];
} Environment;

// This function lives in main.c and not trie.c (where most
// Clause/matching logic lives) because it operates at the Tcl level,
// building up a mapping of strings to Tcl objects. Caller must free
// the returned Environment*.
Environment* clauseUnify(Jim_Interp* interp, Clause* a, Clause* b) {
    Environment* env = malloc(sizeof(Environment) + sizeof(EnvironmentBinding)*a->nTerms);
    env->nBindings = 0;

    for (int i = 0; i < a->nTerms; i++) {
        char aVarName[100] = {0}; char bVarName[100] = {0};
        if (trieScanVariable(a->terms[i], aVarName, sizeof(aVarName))) {
            if (aVarName[0] == '.' && aVarName[1] == '.' && aVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName + 3, sizeof(binding->name) - 3);
                binding->value = termsToJimObj(interp, b->nTerms - i, &b->terms[i]);
            } else if (!trieVariableNameIsNonCapturing(aVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = Jim_NewStringObj(interp, b->terms[i], -1);
            }
        } else if (trieScanVariable(b->terms[i], bVarName, sizeof(bVarName))) {
            if (bVarName[0] == '.' && bVarName[1] == '.' && bVarName[2] == '.') {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName + 3, sizeof(binding->name) - 3);
                binding->value = termsToJimObj(interp, a->nTerms - i, &a->terms[i]);
            } else if (!trieVariableNameIsNonCapturing(bVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = Jim_NewStringObj(interp, a->terms[i], -1);
            }
        } else if (!(a->terms[i] == b->terms[i] ||
                     strcmp(a->terms[i], b->terms[i]) == 0)) {
            free(env);
            fprintf(stderr, "clauseUnify: Unification of (%s) (%s) failed\n",
                    clauseToString(a), clauseToString(b));
            return NULL;
        }
    }
    return env;
}

// Assert! the time is 3
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause = jimArgsToClause(argc, argv);

    Jim_Obj* scriptObj = interp->currentScriptObj;
    const char* sourceFileName;
    int sourceLineNumber;
    if (Jim_ScriptGetSourceFileName(interp, scriptObj, &sourceFileName) != JIM_OK) {
        sourceFileName = "<unknown>";
    }
    if (Jim_ScriptGetSourceLineNumber(interp, scriptObj, &sourceLineNumber) != JIM_OK) {
        sourceLineNumber = -1;
    }

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = ASSERT,
       .thread = -1,
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
    Clause* pattern = jimArgsToClause(argc, argv);

    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RETRACT,
       .thread = -1,
       .retract = { .pattern = pattern }
    });

    return (JIM_OK);
}

static void reactToNewStatement(StatementRef ref);

int64_t _Atomic latestVersion = 0; // TODO: split by key?
void HoldStatementGlobally(const char *key, int64_t version,
                           Clause *clause, long keepMs,
                           const char *sourceFileName, int sourceLineNumber) {
#ifdef TRACY_ENABLE
    char *s = clauseToString(clause);
    TracyCMessageFmt("hold: %.300s", s); free(s);
#endif

    StatementRef oldRef; StatementRef newRef;

    newRef = dbHoldStatement(db, key, version,
                             clause,
                             sourceFileName, sourceLineNumber,
                             &oldRef);
    if (!statementRefIsNull(newRef)) {
        reactToNewStatement(newRef);
    }
    if (!statementRefIsNull(oldRef)) {
        if (keepMs > 0) {
            // We need to delay the react to removed statement
            // until the estimated convergence time of the new
            // statement has elapsed (a few milliseconds?)
            sysmonRemoveAfter(oldRef, keepMs);
        } else {
            Statement* stmt;
            if ((stmt = statementAcquire(db, oldRef))) {
                statementDecrParentCountAndMaybeRemoveSelf(db, stmt);
                statementRelease(db, stmt);
            }
        }
    }
}
static int HoldStatementGloballyFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 4);

    const char *key = Jim_GetString(argv[1], NULL);
    int64_t version = ++latestVersion;
    Clause *clause = jimObjToClause(interp, argv[2]);
    long keepMs; Jim_GetLong(interp, argv[3], &keepMs);

    HoldStatementGlobally(key, version,
                          clause, keepMs,
                          "<unknown>", -1);
    return (JIM_OK);
}

static int SayFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_Obj* scriptObj = interp->currentScriptObj;
    const char* sourceFileName;
    int sourceLineNumber;
    if (Jim_ScriptGetSourceFileName(interp, scriptObj, &sourceFileName) != JIM_OK) {
        sourceFileName = "<unknown>";
    }
    if (Jim_ScriptGetSourceLineNumber(interp, scriptObj, &sourceLineNumber) != JIM_OK) {
        sourceLineNumber = -1;
    }

    Clause* clause;
    int thread = -1;
    if (Jim_String(argv[1])[0] == '@') {
        clause = jimArgsToClause(argc - 1, argv + 1);
        thread = atoi(Jim_String(argv[1]));
    } else {
        clause = jimArgsToClause(argc, argv);
    }

    MatchRef parent;
    if (self->currentMatch) {
        parent = matchRef(db, self->currentMatch);
    } else {
        parent = MATCH_REF_NULL;
        char *s = clauseToString(clause);
        fprintf(stderr, "Warning: Creating unparented Say (%.100s)\n",
                s);
        free(s);
    }


    StatementRef ref;
    ref = dbInsertOrReuseStatement(db, clause,
                                   sourceFileName,
                                   sourceLineNumber,
                                   parent);

    if (!statementRefIsNull(ref)) {
        reactToNewStatement(ref);
    }
    return (JIM_OK);
}
static void destructorHelper(void* arg) {
    // This dispatches an evaluation task to the global queue, so that
    // this function can be invoked from sysmon (which doesn't have
    // its own Tcl interpreter & work queue).

    char* code = (char*) arg;

    globalWorkQueuePush((WorkQueueItem) {
            .op = EVAL,
            .thread = -1,
            .eval = { .code = code }
        });
}
static int DestructorFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    matchAddDestructor(self->currentMatch,
                       destructorHelper,
                       strdup(Jim_GetString(argv[1], NULL)));
    return JIM_OK;
}
static int QueryFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* pattern = jimArgsToClause(argc, argv);

    ResultSet* rs = dbQuery(db, pattern);
    int nResults = (int) rs->nResults;

    Jim_Obj *ret = Jim_NewListObj(interp, NULL, 0);
    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* result = statementAcquire(db, rs->results[i]);
        if (result == NULL) { continue; }

        Environment* env = clauseUnify(interp, pattern, statementClause(result));
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

        free(env);
        statementRelease(db, result);
    }

    clauseFree(pattern);
    free(rs);

    Jim_SetResult(interp, ret);
    return JIM_OK;
}
static int __scanVariableFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    char varName[100];
    if (trieScanVariable(Jim_String(argv[1]), varName, 100)) {
        Jim_SetResultString(interp, varName, strlen(varName));
    } else {
        Jim_SetResultBool(interp, false);
    }
    return JIM_OK;
}
static int __variableNameIsNonCapturingFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    Jim_SetResultBool(interp, trieVariableNameIsNonCapturing(Jim_String(argv[1])));
    return JIM_OK;
}
static int __startsWithDollarSignFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    Jim_SetResultBool(interp, Jim_String(argv[1])[0] == '$');
    return JIM_OK;
}
static int __currentMatchRefFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    MatchRef ref = matchRef(db, self->currentMatch);
    char ret[100]; snprintf(ret, 100, "m%u:%u", ref.idx, ref.gen);
    Jim_SetResultString(interp, ret, strlen(ret));
    return JIM_OK;
}
static int __isWhenOfCurrentMatchAlreadyRunningFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 1);
    StatementRef whenRef = STATEMENT_REF_NULL;
    mutexLock(&self->currentItemMutex);
    if (self->currentItem.op == RUN) {
        whenRef = self->currentItem.run.when;
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
static int __exitFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    long exitCode; Jim_GetLong(interp, argv[1], &exitCode);
    exit(exitCode);
    return JIM_OK;
}

static void interpBoot() {
    interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    Jim_CreateCommand(interp, "Assert!", AssertFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Retract!", RetractFunc, NULL, NULL);
    Jim_CreateCommand(interp, "HoldStatementGlobally!", HoldStatementGloballyFunc, NULL, NULL);

    Jim_CreateCommand(interp, "Say", SayFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Destructor", DestructorFunc, NULL, NULL);

    Jim_CreateCommand(interp, "Query!", QueryFunc, NULL, NULL);

    Jim_CreateCommand(interp, "__scanVariable", __scanVariableFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__currentMatchRef", __currentMatchRefFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__isWhenOfCurrentMatchAlreadyRunning", __isWhenOfCurrentMatchAlreadyRunningFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__isTracyEnabled", __isTracyEnabledFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__db", __dbFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__threadId", __threadIdFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__exit", __exitFunc, NULL, NULL);
    if (Jim_EvalFile(interp, "prelude.tcl") == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "prelude: %s\n", Jim_GetString(Jim_GetResult(interp), NULL));
        exit(1);
    }
}
void eval(const char* code) {
    if (interp == NULL) { interpBoot(); }

    int error = Jim_Eval(interp, code);
    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "eval: (%s) -> (%s)\n", code, Jim_GetString(Jim_GetResult(interp), NULL));
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);
    }
}

//////////////////////////////////////////////////////////
// Evaluator
//////////////////////////////////////////////////////////

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

    // Now when is definitely non-null and stmt is non-null if
    // applicable.

    Clause* whenClause = statementClause(when);
    Clause* stmtClause = stmt == NULL ? whenPattern : statementClause(stmt);

    assert(whenClause->nTerms >= 5);

    // when the time is /t/ /lambdaExpr/ with environment /capturedArgs/
    const char* lambdaExpr = whenClause->terms[whenClause->nTerms - 4];
    const char* capturedArgs = whenClause->terms[whenClause->nTerms - 1];
    Jim_Obj *capturedArgsObj = Jim_NewStringObj(interp, capturedArgs, -1);

    Jim_Obj *lambdaExprObj = Jim_NewStringObj(interp, lambdaExpr, -1);
    // Set the source info for the lambdaExpr:
    Jim_Obj *lambdaBodyObj = Jim_ListGetIndex(interp, lambdaExprObj, 1);
    Jim_SetSourceInfo(interp, lambdaBodyObj,
                      Jim_NewStringObj(interp, statementSourceFileName(when), -1),
                      statementSourceLineNumber(when));

    // Figure out all the bound match variables by unifying when &
    // stmt:
    Environment* env = clauseUnify(interp, whenPattern, stmtClause);
    assert(env != NULL);
    Jim_Obj *whenArgs[env->nBindings];
    for (int i = 0; i < env->nBindings; i++) {
        whenArgs[i] = env->bindings[i].value;
    }
    Jim_Obj *whenArgsObj = Jim_NewListObj(interp, whenArgs, env->nBindings);
    free(env);

    statementRelease(db, when);
    if (stmt != NULL) { statementRelease(db, stmt); }

    if (stmt != NULL) {
        StatementRef parents[] = { whenRef, stmtRef };
        self->currentMatch = dbInsertMatch(db, 2, parents, pthread_self());
    } else {
        StatementRef parents[] = { whenRef };
        self->currentMatch = dbInsertMatch(db, 1, parents, pthread_self());
    }
    if (!self->currentMatch) {
        // A parent is gone. Abort.
        return;
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
            lambdaExprObj,
            capturedArgsObj,
            whenArgsObj
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
                lambdaExpr, errorMessage);
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);
    } else if (error == JIM_SIGNAL) {
        /* fprintf(stderr, "Signal\n"); */
        interp->sigmask = 0;
    }

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;
}
// Copies the whenPattern Clause and all terms so it can be owned (and
// freed) by the eventual handler of the block.
static void pushRunWhenBlock(StatementRef when, Clause* whenPattern, StatementRef stmt) {
    appropriateWorkQueuePush((WorkQueueItem) {
       .op = RUN,
       .thread = -1,
       .run = { .when = when, .whenPattern = clauseDup(whenPattern), .stmt = stmt }
    });
}

// Prepends `/someone/ claims` to `clause`. Returns NULL if `clause`
// shouldn't be claimized. Returns a new heap-allocated Clause* that
// must be freed by the caller.
static Clause* claimizeClause(Clause* clause) {
    if (clause->nTerms >= 2 &&
        (strcmp(clause->terms[1], "claims") == 0 ||
         strcmp(clause->terms[1], "wishes") == 0)) {
        return NULL;
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    Clause* ret = malloc(SIZEOF_CLAUSE(2 + clause->nTerms));
    ret->nTerms = 2 + clause->nTerms;
    ret->terms[0] = "/someone/"; ret->terms[1] = "claims";
    for (int i = 0; i < clause->nTerms; i++) {
        ret->terms[2 + i] = clause->terms[i];
    }
    return ret;
}
static Clause* unclaimizeClause(Clause* clause) {
    // Omar claims the time is 3
    //   -> the time is 3
    Clause* ret = malloc(SIZEOF_CLAUSE(clause->nTerms - 2));
    ret->nTerms = 0;
    for (int i = 2; i < clause->nTerms; i++) {
        ret->terms[ret->nTerms++] = clause->terms[i];
    }
    return ret;
}
static Clause* whenizeClause(Clause* clause) {
    // the time is /t/
    //   -> when the time is /t/ /__lambda/ with environment /__env/
    Clause* ret = malloc(SIZEOF_CLAUSE(clause->nTerms + 5));
    ret->nTerms = clause->nTerms + 5;
    ret->terms[0] = "when";
    for (int i = 0; i < clause->nTerms; i++) {
        ret->terms[1 + i] = clause->terms[i];
    }
    ret->terms[1 + clause->nTerms] = "/__lambda/";
    ret->terms[2 + clause->nTerms] = "with";
    ret->terms[3 + clause->nTerms] = "environment";
    ret->terms[4 + clause->nTerms] = "/__env/";
    return ret;
}
static Clause* unwhenizeClause(Clause* whenClause) {
    // when the time is /t/ /lambda/ with environment /env/
    //   -> the time is /t/
    Clause* ret = malloc(SIZEOF_CLAUSE(whenClause->nTerms - 5));
    ret->nTerms = 0;
    for (int i = 1; i < whenClause->nTerms - 4; i++) {
        ret->terms[ret->nTerms++] = whenClause->terms[i];
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

    if (strcmp(clause->terms[0], "when") == 0) {
        // Find the query pattern of the when:
        Clause* pattern = unwhenizeClause(clause);
        if (pattern->nTerms == 0) {
            // Empty pattern: When { ... }
            pushRunWhenBlock(ref, pattern, STATEMENT_REF_NULL);
            free(pattern);

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
            free(pattern);
            free(claimizedPattern);
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
                statementRelease(db, when);

                pushRunWhenBlock(whenRef, whenPattern, ref);
                free(whenPattern); // doesn't own any terms.
            }
        }
        free(existingReactingWhens);

        free(whenizedClause); // doesn't own any terms.
    }
    if (clause->nTerms >= 2 && strcmp(clause->terms[1], "claims") == 0) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Clause* unclaimizedClause = unclaimizeClause(clause);
        Clause* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        free(unclaimizedClause);
        free(whenizedUnclaimizedClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            if (when) {
                Clause* unwhenizedWhenPattern = unwhenizeClause(statementClause(when));
                Clause* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);
                statementRelease(db, when);

                pushRunWhenBlock(whenRef, claimizedUnwhenizedWhenPattern, ref);
                free(unwhenizedWhenPattern);
                free(claimizedUnwhenizedWhenPattern);
            }
        }
        free(existingReactingWhens);
    }
    statementRelease(db, stmt);
}

void workerRun(WorkQueueItem item) {
#ifdef TRACY_ENABLE
    TracyCZoneCtx zone;
    if (item.op == ASSERT) {
        TracyCZoneN(ctx, "ASSERT", 1); zone = ctx;
    } else if (item.op == RETRACT) {
        TracyCZoneN(ctx, "RETRACT", 1); zone = ctx;
    } else if (item.op == RUN) {
        TracyCZoneN(ctx, "RUN", 1); zone = ctx;
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

        StatementRef ref;
        ref = dbInsertOrReuseStatement(db, item.assert.clause,
                                       item.assert.sourceFileName,
                                       item.assert.sourceLineNumber,
                                       MATCH_REF_NULL);
        if (!statementRefIsNull(ref)) {
            reactToNewStatement(ref);
        }
        free(item.assert.sourceFileName);

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */

        dbRetractStatements(db, item.retract.pattern);
        clauseFree(item.retract.pattern);

    } else if (item.op == RUN) {
        /* printf("  when: %d:%d; stmt: %d:%d\n", item.run.when.idx, item.run.when.gen, */
        /*        item.run.stmt.idx, item.run.stmt.gen); */
        runWhenBlock(item.run.when, item.run.whenPattern, item.run.stmt);
        clauseFree(item.run.whenPattern);

    } else if (item.op == EVAL) {
        // Used for destructors.
        char* code = item.eval.code;
        int error = Jim_Eval(interp, code);
        if (error == JIM_ERR) {
            Jim_MakeErrorMessage(interp);
            fprintf(stderr, "destructorHelper: (%s) -> (%s)\n", code, Jim_GetString(Jim_GetResult(interp), NULL));
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
    int threadIndex = self->index;
    if (item.op == ASSERT) {
        snprintf(buf, bufsz, "Assert (%.100s)",
                 clauseToString(item.assert.clause));
    } else if (item.op == RETRACT) {
        snprintf(buf, bufsz, "Retract (%.100s)",
                 clauseToString(item.retract.pattern));
    } else if (item.op == RUN) {
        Statement* stmt = statementUnsafeGet(db, item.run.stmt);
        snprintf(buf, bufsz, "Run when (%.100s) (%.100s)",
                 clauseToString(item.run.whenPattern),
                 stmt != NULL ? clauseToString(statementClause(stmt)) : "NULL");
    } else if (item.op == EVAL) {
        snprintf(buf, bufsz, "Eval");
    } else if (item.op == NONE) {
        snprintf(buf, bufsz, "NONE");
    } else {
        snprintf(buf, bufsz, "???");
    }
}
void trace(const char* format, ...) {
    int traceIdx = traceNextIdx++;

    char* dest = (traceIdx < TRACE_HEAD_COUNT) ?
        traceHead[traceIdx] :
        traceTail[(traceIdx - TRACE_HEAD_COUNT) % TRACE_TAIL_COUNT];
    size_t n = TRACE_ENTRY_SIZE;
    n -= snprintf(dest, n, "%d: ", self == NULL ? -1 : self->index);

    dest += TRACE_ENTRY_SIZE - n;

    va_list args;
    va_start(args, format);
    vsnprintf(dest, n, format, args);
    va_end(args);
}

ssize_t unsafe_workQueueSize(WorkQueue* q);
__thread unsigned int seedp;
WorkQueueItem workerSteal() {
    int stealee;
    do {
        stealee = rand_r(&seedp) % threadCount;
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

#ifdef FOLK_TRACE
        char buf[1000]; traceItem(buf, sizeof(buf), item);
        trace("%s", buf);
#endif

        if (item.op != NONE &&
            item.thread != -1 &&
            item.thread != self->index) {

            fprintf(stderr, "folk: UNIMPLEMENTED: wrong thread for item\n");
            exit(1);
        }

        workerRun(item);
    }
 die:
    // Note that our workqueue should be empty at this point.
    fprintf(stderr, "%d: Die\n", self->index);
    self->tid = 0;
}
void workerInit(int index) {
    seedp = time(NULL) + index;

    self = &threads[index];
    if (self->workQueue == NULL) {
        self->workQueue = workQueueNew();
        self->currentItem = (WorkQueueItem) { .op = NONE };
        mutexInit(&self->currentItemMutex);

        self->isDeactivated = false;
        sem_init(&self->reactivate, 0, 0);
    }

    epochThreadInit();

#ifdef __linux__
    if (pthread_getcpuclockid(pthread_self(), &self->clockid)) {
        perror("workerInit: pthread_getcpuclockid failed");
    }
#else
    self->clockid = CLOCK_MONOTONIC;
#endif
    self->currentItemStartTimestamp = 0;
    self->index = index;

#ifdef TRACY_ENABLE
    char threadName[100]; snprintf(threadName, 100, "folk-worker-%d", index);
    TracyCSetThreadName(threadName);
#endif

    interpBoot();
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
void workerReactivateOrSpawn() {
    for (int i = 0; i < THREADS_MAX; i++) {
        if (threads[i].tid != 0 && threads[i].isDeactivated) {
            sem_post(&threads[i].reactivate);
            return;
        }
    }
    fprintf(stderr, "workerSpawn\n");
    workerSpawn();
}

int main(int argc, char** argv) {
    // Do all setup.

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
    int cpuUsableCount = 3;
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

    if (argc == 1) {
        eval("source boot.folk");
    } else {
        char code[100]; snprintf(code, 100, "source %s", argv[1]);
        eval(code);
    }

#ifdef __APPLE__
    if (argc == 1) {
        // Hard-coded. If there's no specific script to run, so we're
        // just running the full boot, then make sure to run the GPU
        // on the main thread. Run the GPU in apply so that there's a
        // local scope to be lexically captured.
        eval("apply {{} {source virtual-programs/gpu.folk}}");
    }
#endif

    workerLoop();
}
