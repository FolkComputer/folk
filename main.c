#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <assert.h>

#define JIM_EMBEDDED
#include <jim.h>

#include <pqueue.h>

#include "db.h"
#include "workqueue.h"

Db* db;
pthread_mutex_t dbMutex;

WorkQueue* workQueue;
pthread_mutex_t workQueueMutex;

static Clause* jimArgsToClause(int argc, Jim_Obj *const *argv) {
    Clause* clause = malloc(SIZEOF_CLAUSE(argc - 1));
    clause->nTerms = argc - 1;
    for (int i = 1; i < argc; i++) {
        clause->terms[i - 1] = strdup(Jim_GetString(argv[i], NULL));
    }
    return clause;
}
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause = jimArgsToClause(argc, argv);

    pthread_mutex_lock(&workQueueMutex);
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = ASSERT,
       .assert = { .clause = clause }
    });
    pthread_mutex_unlock(&workQueueMutex);

    return (JIM_OK);
}
static int RetractFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* pattern = jimArgsToClause(argc, argv);

    pthread_mutex_lock(&workQueueMutex);
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = RETRACT,
       .retract = { .pattern = pattern }
    });
    pthread_mutex_unlock(&workQueueMutex);

    return (JIM_OK);
}
__thread int threadId = -1;
__thread Match* currentMatch = NULL;
static int SayFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause = jimArgsToClause(argc, argv);

    pthread_mutex_lock(&workQueueMutex);
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = SAY,
       .say = {
           .parent = currentMatch,
           .clause = clause
       }
    });
    pthread_mutex_unlock(&workQueueMutex);

    return (JIM_OK);
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
static int __threadIdFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Jim_SetResultInt(interp, threadId);
    return JIM_OK;
}
static int __exitFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    long exitCode; Jim_GetLong(interp, argv[1], &exitCode);
    exit(exitCode);
    return JIM_OK;
}

__thread Jim_Interp* interp = NULL;
static void interpBoot() {
    interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);
    Jim_CreateCommand(interp, "Assert", AssertFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Retract", RetractFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Say", SayFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__scanVariable", __scanVariableFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__variableNameIsNonCapturing", __variableNameIsNonCapturingFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__startsWithDollarSign", __startsWithDollarSignFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__threadId", __threadIdFunc, NULL, NULL);
    Jim_CreateCommand(interp, "__exit", __exitFunc, NULL, NULL);
    Jim_EvalFile(interp, "main.tcl");
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

////// Evaluator //////////////

static void runWhenBlock(Statement* when, Clause* whenPattern, Statement* stmt) {
    // TODO: Free clauseToString
    /* printf("runWhenBlock:\n  When: (%s)\n  Stmt: (%s)\n", */
    /*        clauseToString(statementClause(when)), */
    /*        clauseToString(statementClause(stmt))); */

    Clause* whenClause = statementClause(when);
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
    Environment* env = clauseUnify(whenPattern, statementClause(stmt));
    assert(env != NULL);
    Jim_Obj* envArgs[env->nBindings];
    for (int i = 0; i < env->nBindings; i++) {
        envArgs[i] = Jim_NewStringObj(interp, env->bindings[i].value, -1);
    }
    Jim_ListInsertElements(interp, expr,
                           Jim_ListLength(interp, expr),
                           env->nBindings, envArgs);
    free(env);

    pthread_mutex_lock(&dbMutex);
    Statement* parents[] = { when, stmt };
    dbInsertMatch(db, 2, parents, &currentMatch);
    pthread_mutex_unlock(&dbMutex);

    int error = Jim_EvalObj(interp, expr);

    if (error == JIM_ERR) {
        Jim_MakeErrorMessage(interp);
        fprintf(stderr, "runWhenBlock: (%s) -> (%s)\n",
                lambda,
                Jim_GetString(Jim_GetResult(interp), NULL));
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);
    }
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
    return clause;
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

// React to the addition of a new statement (fire any relevant
// existing Whens & if the new statement is a When, then fire it with
// respect to any relevant existing statements).
static void reactToNewStatement(Statement* stmt) {
    Clause* clause = statementClause(stmt);

    // TODO: implement collected matches

    if (strcmp(clause->terms[0], "when") == 0) {
        // Find the query pattern of the when:
        Clause* pattern = unwhenizeClause(clause);

        // Scan the existing statement set for any already-existing
        // matching statements.
        pthread_mutex_lock(&dbMutex);
        ResultSet* existingMatchingStatements = dbQuery(db, pattern);
        // TODO: lease result statements so they don't get freed? hazard pointer?
        pthread_mutex_unlock(&dbMutex);
        for (int i = 0; i < existingMatchingStatements->nResults; i++) {
            runWhenBlock(stmt, pattern,
                         existingMatchingStatements->results[i]);
        }
        free(existingMatchingStatements);

        Clause* claimizedPattern = claimizeClause(pattern);
        if (claimizedPattern) {
            pthread_mutex_lock(&dbMutex);
            existingMatchingStatements = dbQuery(db, claimizedPattern);
            // TODO: lease result statements so they don't get freed? hazard pointer?
            pthread_mutex_unlock(&dbMutex);
            for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                runWhenBlock(stmt, claimizedPattern,
                             existingMatchingStatements->results[i]);
            }
            free(existingMatchingStatements);
            free(claimizedPattern);
        }
        free(pattern);
    }

    // Trigger any already-existing reactions to the addition of this
    // statement (look for Whens that are already in the database).
    {
        // the time is 3
        //   -> when the time is 3 /__lambda/ with environment /__env/
        Clause* whenizedClause = whenizeClause(clause);

        pthread_mutex_lock(&dbMutex);
        ResultSet* existingReactingWhens = dbQuery(db, whenizedClause);
        // TODO: lease result statements so they don't get freed?
        // hazard pointer?
        pthread_mutex_unlock(&dbMutex);
        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> the time is /t/
            Statement* when = existingReactingWhens->results[i];
            Clause* whenPattern = unwhenizeClause(statementClause(when));
            runWhenBlock(when, whenPattern, stmt);
            free(whenPattern);
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

        pthread_mutex_lock(&dbMutex);
        ResultSet* existingReactingWhens = dbQuery(db, whenizedUnclaimizedClause);
        // TODO: lease result statements so they don't get freed?
        // hazard pointer?
        pthread_mutex_unlock(&dbMutex);
        free(unclaimizedClause);
        free(whenizedUnclaimizedClause);

        for (int i = 0; i < existingReactingWhens->nResults; i++) {
            // when the time is /t/ /__lambda/ with environment /__env/
            //   -> /someone/ claims the time is /t/
            Statement* when = existingReactingWhens->results[i];
            Clause* claimizedWhenPattern = claimizeClause(unwhenizeClause(statementClause(when)));
            runWhenBlock(when, claimizedWhenPattern, stmt);
            free(claimizedWhenPattern);
        }
        free(existingReactingWhens);
    }

    // TODO: look for collects in the db
    
}
static void reactToRemovedStatement(Statement* stmt) {
    // walk through edges to matches
    /* ListOfEdgeToMatch */
    // for each parent match: remove edge from it to stmt

    // for each child match:
    //   react to removed match
    //   remove match
}
void workerRun(WorkQueueItem item) {
    if (item.op == ASSERT) {
        /* printf("Assert (%s)\n", clauseToString(item.assert.clause)); */

        Statement* stmt; bool isNewStmt;
        pthread_mutex_lock(&dbMutex);
        dbInsertStatement(db, item.assert.clause, 0, NULL, &stmt, &isNewStmt);
        // TODO: lease stmt / stmt's clause so it doesn't get freed? hazard pointer?
        pthread_mutex_unlock(&dbMutex);

        if (isNewStmt) { reactToNewStatement(stmt); }

    } else if (item.op == RETRACT) {
        printf("retract\n");

        pthread_mutex_lock(&dbMutex);
        // This removes the statements from the lookup index, so they
        // won't appear as query results, but it doesn't disconnect
        // them or free them.
        ResultSet* retractStmts = dbRemoveStatements(db, item.retract.pattern);
        pthread_mutex_unlock(&dbMutex);

        for (int i = 0; i < retractStmts->nResults; i++) {
            reactToRemovedStatement(retractStmts->results[i]);
        }
        free(retractStmts);

    } else if (item.op == SAY) {
        // TODO: Check if match still exists

        printf("Say (%p) (%s)\n", item.say.parent, clauseToString(item.say.clause));

        Statement* stmt; bool isNewStmt;
        pthread_mutex_lock(&dbMutex);
        dbInsertStatement(db, item.say.clause, 1, &item.say.parent,
                          &stmt, &isNewStmt);
        pthread_mutex_unlock(&dbMutex);

        if (isNewStmt) { reactToNewStatement(stmt); }

    } else {
        printf("other\n");
    }
}
void* workerMain(void* arg) {
    threadId = (int) (intptr_t) arg;

    interpBoot();

    for (;;) {
        pthread_mutex_lock(&workQueueMutex);
        WorkQueueItem item = workQueuePop(workQueue);
        pthread_mutex_unlock(&workQueueMutex);

        // TODO: if item is none, then sleep or wait on condition
        // variable.
        if (item.op == NONE) { usleep(100000); continue; }

        /* printf("Worker %d: ", id, item.op); */
        workerRun(item);
    }
}



static void trieWriteToPdf(Trie* trie) {
    char code[500];
    snprintf(code, 500,
             "source db.tcl; "
             "trieWriteToPdf {(Trie*) %p} trie.pdf; puts trie.pdf", trie);
    eval(code);
}
static void dbWriteToPdf(Db* db) {
    char code[500];
    snprintf(code, 500,
             "source db.tcl; "
             "dbWriteToPdf {(Db*) %p} db.pdf; puts db.pdf", db);
    eval(code);
}
static void exitHandler() {
    pthread_mutex_lock(&dbMutex);
    trieWriteToPdf(dbGetClauseToStatementId(db));
    dbWriteToPdf(db);
    pthread_mutex_unlock(&dbMutex);
}
int main() {
    // Do all setup.

    // Set up database.
    db = dbNew();
    pthread_mutex_init(&dbMutex, NULL);

    // Set up workqueue.
    workQueue = workQueueNew();
    pthread_mutex_init(&workQueueMutex, NULL);

    // Queue up some items (JUST FOR TESTING)
    eval("puts {main: Main}; source test.tcl");

    // Spawn NCPUS workers.
    pthread_t th[4];
    for (int i = 0; i < 4; i++) {
        pthread_create(&th[i], NULL, workerMain, (void*) (intptr_t) i);
    }

    atexit(exitHandler);
    for (int i = 0; i < 4; i++) {
        pthread_join(th[i], NULL);
    }
}
