#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>

#define JIM_EMBEDDED
#include <jim.h>

#include <pqueue.h>

#include "db.h"
#include "workqueue.h"

typedef struct ThreadControlBlock {
    int index;
    pid_t tid;

    WorkQueue* workQueue;

    // Used for diagnostics/profiling.
    WorkQueueItem currentItem;
    pthread_mutex_t currentItemMutex;

    // Current match being constructed (if applicable).
    Match* currentMatch;
} ThreadControlBlock;

ThreadControlBlock threads[100];
int _Atomic threadCount;
__thread ThreadControlBlock* self;

__thread Jim_Interp* interp = NULL;

Db* db;

#ifdef TRACE
WorkQueueItem trace[50000];
int traceThreadIndex[50000];
int _Atomic traceNextIdx = 0;
#endif

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
// building up a Tcl value which may be a singleton or a list. Caller
// must free the returned Environment*.
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

    workQueuePush(self->workQueue, (WorkQueueItem) {
       .op = ASSERT,
       .thread = -1,
       .assert = { .clause = clause }
    });

    return (JIM_OK);
}
// Retract! the time is /t/
static int RetractFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* pattern = jimArgsToClause(argc, argv);

    workQueuePush(self->workQueue, (WorkQueueItem) {
       .op = RETRACT,
       .thread = -1,
       .retract = { .pattern = pattern }
    });

    return (JIM_OK);
}
// Hold! {Omar's time} {the time is 3}
int64_t _Atomic latestVersion = 0; // TODO: split by key?
static int HoldFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 3);
    const char* key = strdup(Jim_GetString(argv[1], NULL));
    Clause* clause = jimObjToClause(interp, argv[2]);

    workQueuePush(self->workQueue, (WorkQueueItem) {
       .op = HOLD,
       .thread = -1,
       .hold = { .key = key, .version = ++latestVersion,
                 .clause = clause, }
    });

    return (JIM_OK);
}

static int SayFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause;
    int thread = -1;
    if (Jim_String(argv[1])[0] == '@') {
        clause = jimArgsToClause(argc - 1, argv + 1);
        thread = atoi(Jim_String(argv[1]));
    } else {
        clause = jimArgsToClause(argc, argv);
    }

    workQueuePush(self->workQueue, (WorkQueueItem) {
       .op = SAY,
       .thread = thread,
       .say = {
           .parent = matchRef(db, self->currentMatch),
           .clause = clause,
       }
    });

    return (JIM_OK);
}
static void destructorHelper(void* arg) {
    char* code = (char*) arg;
    int error = Jim_Eval(interp, code);
    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "destructorHelper: (%s) -> (%s)\n", code, Jim_GetString(Jim_GetResult(interp), NULL));
    }
    free(code);
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
    Jim_Obj* resultObjs[nResults];
    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* result = statementAcquire(db, rs->results[i]);
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

        resultObjs[i] = Jim_NewDictObj(interp, envDict, (env->nBindings + 1) * 2);
        free(env);
        statementRelease(db, result);
    }
    free(pattern);
    free(rs);
    Jim_SetResult(interp, Jim_NewListObj(interp, resultObjs, nResults));
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
    Jim_CreateCommand(interp, "Hold!", HoldFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Say", SayFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Destructor", DestructorFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Query!", QueryFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__scanVariable", __scanVariableFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__db", __dbFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__threadId", __threadIdFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__exit", __exitFunc, NULL, NULL);
    Jim_EvalFile(interp, "prelude.tcl");
}
static void eval(const char* code) {
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
    Statement* when = statementAcquire(db, whenRef);
    Statement* stmt = statementAcquire(db, stmtRef);
    if (when == NULL || stmt == NULL) {
        if (when != NULL) { statementRelease(db, when); }
        if (stmt != NULL) { statementRelease(db, stmt); }
        /* printf("Dead: when %p, stmt %p\n", when, stmt); */
        return;
    }

    Clause* whenClause = statementClause(when);
    Clause* stmtClause = statementClause(stmt);

    // TODO: Free clauseToString
    /* printf("runWhenBlock:\n  When: (%s)\n  Stmt: (%s)\n", */
    /*        clauseToString(statementClause(when)), */
    /*        clauseToString(statementClause(stmt))); */

    assert(whenClause->nTerms >= 6);

    // when the time is /t/ /lambda/ with environment /builtinEnv/
    const char* lambda = whenClause->terms[whenClause->nTerms - 4];
    const char* builtinEnv = whenClause->terms[whenClause->nTerms - 1];

    Jim_Obj* expr = Jim_NewStringObj(interp, builtinEnv, -1);

    // Prepend `apply $lambda` to expr:
    Jim_Obj* applyLambda[] = {
        Jim_NewStringObj(interp, "apply", -1),
        Jim_NewStringObj(interp, lambda, -1)
    };
    Jim_ListInsertElements(interp, expr, 0,
                           sizeof(applyLambda)/sizeof(applyLambda[0]),
                           applyLambda);

    // Postpend bound variables to expr:
    Environment* env = clauseUnify(interp, whenPattern, stmtClause);
    assert(env != NULL);
    Jim_Obj* envArgs[env->nBindings];
    for (int i = 0; i < env->nBindings; i++) {
        envArgs[i] = env->bindings[i].value;
    }
    Jim_ListInsertElements(interp, expr,
                           Jim_ListLength(interp, expr),
                           env->nBindings, envArgs);
    free(env);

    statementRelease(db, stmt);
    statementRelease(db, when);

    StatementRef parents[] = { whenRef, stmtRef };

    self->currentMatch = dbInsertMatch(db, 2, parents, pthread_self());
    if (!self->currentMatch) {
        // A parent is gone. Abort.
        return;
    }

    // Rule: you should never be holding a lock while doing a Tcl
    // evaluation.
    interp->signal_level++;
    int error = Jim_EvalObj(interp, expr);
    interp->signal_level--;

    matchCompleted(self->currentMatch);
    matchRelease(db, self->currentMatch);
    self->currentMatch = NULL;

    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "Error: runWhenBlock: (%.100s) -> (%s)\n",
                lambda,
                Jim_GetString(Jim_GetResult(interp), NULL));
        /* Jim_FreeInterp(interp); */
        /* exit(EXIT_FAILURE); */
    } else if (error == JIM_SIGNAL) {
        /* fprintf(stderr, "Signal\n"); */
        interp->sigmask = 0;
    }
}
static void pushRunWhenBlock(StatementRef when, Clause* whenPattern, StatementRef stmt) {
    workQueuePush(self->workQueue, (WorkQueueItem) {
       .op = RUN,
       .thread = -1,
       .run = { .when = when, .whenPattern = whenPattern, .stmt = stmt }
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
// respect to any pertinent existing statements. Should be called with
// the database lock held.
static void reactToNewStatement(StatementRef ref, Clause* clause) {
    // TODO: implement collected matches

    if (strcmp(clause->terms[0], "when") == 0) {
        // Find the query pattern of the when:
        Clause* pattern = unwhenizeClause(clause);

        // Scan the existing statement set for any already-existing
        // matching statements.
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
    }

    // Trigger any already-existing reactions to the addition of this
    // statement (look for Whens that are already in the database).
    {
        // the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Clause* whenizedClause = whenizeClause(clause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedClause);
        // TODO: lease result statements so they don't get freed?
        // hazard pointer?
        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            Clause* whenPattern = unwhenizeClause(statementClause(when));
            statementRelease(db, when);

            pushRunWhenBlock(whenRef, whenPattern, ref);
        }
        free(existingReactingWhens);
    }
    if (clause->nTerms >= 2 && strcmp(clause->terms[1], "claims") == 0) {
        // Cut off `/x/ claims` from start of clause:
        //
        // /x/ claims the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Clause* unclaimizedClause = unclaimizeClause(clause);
        Clause* whenizedUnclaimizedClause = whenizeClause(unclaimizedClause);

        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        // TODO: lease result statements so they don't get freed?
        // hazard pointer?
        free(unclaimizedClause);
        free(whenizedUnclaimizedClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            StatementRef whenRef = existingReactingWhens->results[i];
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = statementAcquire(db, whenRef);
            Clause* unwhenizedWhenPattern = unwhenizeClause(statementClause(when));
            Clause* claimizedUnwhenizedWhenPattern = claimizeClause(unwhenizedWhenPattern);
            statementRelease(db, when);

            pushRunWhenBlock(whenRef, claimizedUnwhenizedWhenPattern, ref);
            free(unwhenizedWhenPattern);
        }
        free(existingReactingWhens);
    }
}

void workerRun(WorkQueueItem item) {
    pthread_mutex_lock(&self->currentItemMutex);
    self->currentItem = item;
    pthread_mutex_unlock(&self->currentItemMutex);

    if (item.op == ASSERT) {
        /* printf("Assert (%s)\n", clauseToString(item.assert.clause)); */

        StatementRef ref;
        ref = dbInsertOrReuseStatement(db, item.assert.clause, MATCH_REF_NULL);
        if (!statementRefIsNull(ref)) {
            reactToNewStatement(ref, item.assert.clause);
        }

    } else if (item.op == RETRACT) {
        /* printf("Retract (%s)\n", clauseToString(item.retract.pattern)); */

        dbRetractStatements(db, item.retract.pattern);

    } else if (item.op == HOLD) {
        /* printf("@%d: Hold (%s)\n", self->index, clauseToString(item.hold.clause)); */

        StatementRef oldRef; StatementRef newRef;

        newRef = dbHoldStatement(db, item.hold.key, item.hold.version,
                                 item.hold.clause,
                                 &oldRef);
        if (!statementRefIsNull(newRef)) {
            reactToNewStatement(newRef, item.hold.clause);

            // TODO: Impose a hop limit after which we should carry out the removal.
        
            // We need to delay the react to removed statement until
            // full subconvergence of the addition of the new statement.
            // or just mess with priorities so that the react to removed
            // statement usually gets delayed?
            workQueuePush(self->workQueue, (WorkQueueItem) {
                    .op = REMOVE_PARENT,
                    .thread = -1,
                    .removeParent = { .stmt = oldRef }
                });
        }

    } else if (item.op == SAY) {
        /* printf("@%d: Say (%.100s)\n", self->index, clauseToString(item.say.clause)); */

        StatementRef ref;
        ref = dbInsertOrReuseStatement(db, item.say.clause, item.say.parent);
        if (!statementRefIsNull(ref)) {
            reactToNewStatement(ref, item.say.clause);
        }

    } else if (item.op == RUN) {
        /* printf("@%d: Run when (%.100s)\n", self->index, clauseToString(item.run.whenPattern)); */
        /* printf("  when: %d:%d; stmt: %d:%d\n", item.run.when.idx, item.run.when.gen, */
        /*        item.run.stmt.idx, item.run.stmt.gen); */
        runWhenBlock(item.run.when, item.run.whenPattern, item.run.stmt);

    } else if (item.op == REMOVE_PARENT) {
        Statement* stmt;
        if ((stmt = statementAcquire(db, item.removeParent.stmt))) {
            statementRemoveParentAndMaybeRemoveSelf(db, stmt);
            statementRelease(db, stmt);
        }

    } else {
        fprintf(stderr, "workerRun: Unknown work item op: %d\n",
                item.op);
        exit(1);
    }
}

void workerInit(int index) {
    srand(time(NULL) + index);

    self = &threads[index];
    self->index = index;
#ifdef __APPLE__
    self->tid = pthread_mach_thread_np(pthread_self());
#else
    self->tid = gettid();
#endif
    pthread_mutex_init(&self->currentItemMutex, NULL);

    self->workQueue = workQueueNew();

    interpBoot();
}
void workerLoop() {
    for (;;) {
        WorkQueueItem item = workQueueTake(self->workQueue);
        while (item.op == NONE) {
            // If item is none, then steal from another thread's
            // workqueue:
            int stealee = rand() % threadCount;
            item = workQueueSteal(threads[stealee].workQueue);
        }

#ifdef TRACE
        int traceIdx = traceNextIdx++;
        if (traceIdx >= sizeof(trace)/sizeof(trace[0])) {
            fprintf(stderr, "workerLoop: trace exhausted\n");
            exit(1);
        }
        trace[traceIdx] = item;
        traceThreadIndex[traceIdx] = self->index;
#endif

        /* if (item.op != NONE && */
        /*     item.thread != -1 && */
        /*     item.thread != self->index) { */

        /*     // Skip and requeue. */
        /*     workQueuePush(self->workQueue, item); */
        /*     item.op = NONE; */
        /* } */

        workerRun(item);
    }
}
void* workerMain(void* arg) {
    workerInit((int) (intptr_t) arg);
    workerLoop();
    return NULL;
}

static void trieWriteToPdf() {
    char code[500];
    snprintf(code, 500,
             "proc Wish {args} {}; source virtual-programs/web/trie-graph.folk; "
             "set dot [apply $trieDotify $trieLib [__db]]; "
             "set fd [open trie.pdf w]; puts $fd [apply $getDotAsPdf $dot]; close $fd; "
             "puts trie.pdf");
    eval(code);
}
static void dbWriteToPdf() {
    char code[500];
    snprintf(code, 500,
             "proc Wish {args} {}; source virtual-programs/web/dep-graph.folk; "
             "set dot [apply $dbDotify $dbLib [__db]]; "
             "set fd [open db.pdf w]; puts $fd [apply $getDotAsPdf $dot]; close $fd; "
             "puts db.pdf");
    eval(code);
}
static void exitHandler() {
    printf("exitHandler\n----------\n");

    trieWriteToPdf();
    dbWriteToPdf();
}
int main(int argc, char** argv) {
    // Do all setup.

    // Set up database.
    db = dbNew();
    // TODO: hack
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);

    atexit(exitHandler);

    int NTHREADS = 5;
    threadCount = NTHREADS;

    // Spawn NTHREADS-1 workers. 
    pthread_t th[NTHREADS];
    for (int i = 1; i < NTHREADS; i++) {
        pthread_create(&th[i], NULL, workerMain, (void*) (intptr_t) i);
    }

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
    eval("source virtual-programs/gpu.folk");
#endif
    
    workerLoop();
}
