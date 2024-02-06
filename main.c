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

// FIXME: Implement Assert, When, Claim
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause = malloc(SIZEOF_CLAUSE(argc - 1));
    clause->nTerms = argc - 1;
    for (int i = 1; i < argc; i++) {
        clause->terms[i - 1] = strdup(Jim_GetString(argv[i], NULL));
    }
    pthread_mutex_lock(&workQueueMutex);
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = ASSERT,
       .assert = { .clause = clause }
    });
    pthread_mutex_unlock(&workQueueMutex);
    return (JIM_OK);
}
static int ClaimFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    fprintf(stderr, "ClaimFunc\n"); return (JIM_ERR);
}
static int WhenFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    fprintf(stderr, "WhenFunc\n"); return (JIM_ERR);
}

__thread Jim_Interp* interp = NULL;
static void eval(const char* code) {
    if (interp == NULL) {
        interp = Jim_CreateInterp();
        Jim_RegisterCoreCommands(interp);
        Jim_InitStaticExtensions(interp);
        Jim_CreateCommand(interp, "Assert", AssertFunc, NULL, NULL);
        Jim_CreateCommand(interp, "Claim", ClaimFunc, NULL, NULL);
        Jim_CreateCommand(interp, "When", WhenFunc, NULL, NULL);
    }

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
    /*        clauseToString(when->clause), */
    /*        clauseToString(stmt->clause)); */

    assert(when->clause->nTerms >= 6);

    // when the time is /t/ /lambda/ with environment /builtinEnv/
    const char* lambda = when->clause->terms[when->clause->nTerms - 4];
    const char* builtinEnv = when->clause->terms[when->clause->nTerms - 1];

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
    Environment* env = clauseUnify(whenPattern, stmt->clause);
    Jim_Obj* envArgs[env->nBindings];
    for (int i = 0; i < env->nBindings; i++) {
        envArgs[i] = Jim_NewStringObj(interp, env->bindings[i].value, -1);
    }
    Jim_ListInsertElements(interp, expr,
                           Jim_ListLength(interp, expr),
                           env->nBindings, envArgs);

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
// Prepends `/someone/ claims` to `pattern`. Returns NULL if `pattern`
// shouldn't be claimized. Returns a new heap-allocated Clause* that
// must be freed by the caller.
static Clause* claimizePattern(Clause* pattern) {
    if (pattern->nTerms >= 2 &&
        (strcmp(pattern->terms[1], "claims") == 0 ||
         strcmp(pattern->terms[1], "wishes") == 0)) {
        return NULL;
    }

    // the time is /t/ -> /someone/ claims the time is /t/
    Clause* ret = malloc(SIZEOF_CLAUSE(2 + pattern->nTerms));
    ret->nTerms = 2 + pattern->nTerms;
    ret->terms[0] = "/someone/"; ret->terms[1] = "claims";
    for (int i = 0; i < pattern->nTerms; i++) {
        ret->terms[2 + i] = pattern->terms[i];
    }
    return ret;
}
static void reactToNewStatement(Statement* stmt) {
    Clause* clause = stmt->clause;

    // TODO: implement collected matches

    if (strcmp(clause->terms[0], "when") == 0) {
        // Find the query pattern of the when:
        //   when the time is /t/ { ... } with environment /env/
        //     -> the time is /t/
        Clause* pattern = alloca(SIZEOF_CLAUSE(clause->nTerms - 5));
        pattern->nTerms = 0;
        for (int i = 1; i < clause->nTerms - 4; i++) {
            pattern->terms[pattern->nTerms++] = clause->terms[i];
        }

        // Scan the existing statement set for any already-existing
        // matching statements.

        ResultSet* existingMatchingStatements = dbQuery(db, pattern);
        /* printf("Results for (%s): %d\n", clauseToString(pattern), existingMatchingStatements->nResults); */
        for (int i = 0; i < existingMatchingStatements->nResults; i++) {
            runWhenBlock(stmt, pattern,
                         existingMatchingStatements->results[i]);
        }
        free(existingMatchingStatements);

        Clause* claimizedPattern = claimizePattern(pattern);
        if (claimizedPattern) {
            existingMatchingStatements = dbQuery(db, claimizedPattern);
            for (int i = 0; i < existingMatchingStatements->nResults; i++) {
                runWhenBlock(stmt, claimizedPattern,
                             existingMatchingStatements->results[i]);
            }
            free(existingMatchingStatements);
            free(claimizedPattern);
        }
    }

    // Trigger any already-existing reactions to the addition of this
    // statement. (Look for Whens that are already in the database.)
    Clause* whenPattern = alloca(SIZEOF_CLAUSE(clause->nTerms + 5));
    whenPattern->nTerms = clause->nTerms + 5;
    whenPattern->terms[0] = "when";
    for (int i = 0; i < clause->nTerms; i++) {
        whenPattern->terms[1 + i] = clause->terms[i];
    }
    whenPattern->terms[1 + clause->nTerms] = "/__lambda/";
    whenPattern->terms[2 + clause->nTerms] = "with";
    whenPattern->terms[3 + clause->nTerms] = "environment";
    whenPattern->terms[4 + clause->nTerms] = "/__env/";

    ResultSet* existingReactingWhens = dbQuery(db, whenPattern);
    for (int i = 0; i < existingReactingWhens->nResults; i++) {
        Statement* when = existingReactingWhens->results[i];
        Clause* pattern = alloca(SIZEOF_CLAUSE(when->clause->nTerms - 5));
        pattern->nTerms = 0;
        for (int i = 1; i < when->clause->nTerms - 4; i++) {
            pattern->terms[pattern->nTerms++] = when->clause->terms[i];
        }

        runWhenBlock(when, pattern, stmt);
    }
    free(existingReactingWhens);

    // TODO: look for collects in the db
    
}
void workerRun(WorkQueueItem item) {
    if (item.op == ASSERT) {
        /* printf("Assert (%s)\n", clauseToString(item.assert.clause)); */

        Statement* ret; bool isNewStmt;
        pthread_mutex_lock(&dbMutex);
        dbInsert(db, item.assert.clause, 0, NULL, &ret, &isNewStmt);
        pthread_mutex_unlock(&dbMutex);

        if (isNewStmt) { reactToNewStatement(ret); }

    } else if (item.op == RETRACT) {
        printf("retract\n");
    } else {
        printf("other\n");
    }
}
void* workerMain(void* arg) {
    int id = (int) arg;

    interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);
    Jim_CreateCommand(interp, "Assert", AssertFunc, NULL, NULL);
    Jim_CreateCommand(interp, "Claim", ClaimFunc, NULL, NULL);
    Jim_CreateCommand(interp, "When", WhenFunc, NULL, NULL);

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
int main() {
    // Do all setup.

    // Set up database.
    db = dbNew();
    pthread_mutex_init(&dbMutex, NULL);

    // Set up workqueue.
    workQueue = workQueueNew();
    pthread_mutex_init(&workQueueMutex, NULL);

    // Queue up some items (JUST FOR TESTING)
    eval("puts {main: Main}; source main.tcl");

    // Spawn NCPUS workers.
    for (int i = 0; i < 4; i++) {
        pthread_t th;
        pthread_create(&th, NULL, workerMain, i);
    }

    usleep(5000000);

    printf("main: Done!\n");

    pthread_mutex_lock(&dbMutex);
    trieWriteToPdf(dbGetClauseToStatementId(db));
    dbWriteToPdf(db);
    pthread_mutex_unlock(&dbMutex);
}
