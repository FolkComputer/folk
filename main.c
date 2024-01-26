#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>

#define JIM_EMBEDDED
#include <jim.h>

#include <pqueue.h>

#include "db.h"
#include "workqueue.h"

Db* db;
pthread_mutex_t dbMutex;

WorkQueue* workQueue;
pthread_mutex_t workQueueMutex;

char* printClause(Clause* c) {
    for (int i = 0; i < c->nterms; i++) {
        printf("%s ", c->terms[i]);
    }
}
void workerRun(WorkQueueItem item) {
    if (item.op == ASSERT) {
        /* printf("Assert ("); */
        /* printClause(item.assert.clause); */
        /* printf(")\n"); */

        Statement* ret; bool isNewStmt;
        pthread_mutex_lock(&dbMutex);
        dbInsert(db, item.assert.clause, 0, NULL, &ret, &isNewStmt);
        pthread_mutex_unlock(&dbMutex);

        if (isNewStmt) {
            // TODO: React.
        }

    } else if (item.op == RETRACT) {
        
    }
}
void* workerMain(void* arg) {
    int id = (int) arg;
    for (;;) {
        pthread_mutex_lock(&workQueueMutex);
        WorkQueueItem item = workQueuePop(workQueue);
        pthread_mutex_unlock(&workQueueMutex);

        // TODO: if item is none, then sleep or wait on condition
        // variable.
        if (item.op == NONE) { usleep(100000); continue; }

        printf("Worker %d: item %d\n", id, item.op);
        workerRun(item);
    }
}

// Test:
static void pushAssert(char* text) {
    // Tokenize text by space & build up a Clause:
    char* tofree; char* s;
    tofree = s = strdup(text);
    char* token;
    Clause* c = calloc(sizeof(Clause) + sizeof(char*)*100, 1);
    while ((token = strsep(&s, " ")) != NULL) {
        c->terms[c->nterms++] = strdup(token);
        if (c->nterms >= 100) abort();
    }
    free(tofree);

    // Assert it
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = ASSERT,
       .assert = { .clause = c }
    });
}

// FIXME: Implement Assert, When, Claim
static int AssertFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    Clause* clause = malloc(SIZEOF_CLAUSE(argc - 1));
    clause->nterms = argc - 1;
    for (int i = 1; i < argc; i++) {
        clause->terms[i - 1] = strdup(Jim_GetString(argv[i], NULL));
    }
    workQueuePush(workQueue, (WorkQueueItem) {
       .op = ASSERT,
       .assert = { .clause = clause }
    });
    return (JIM_OK);
}
static int ClaimFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    return (JIM_ERR);
}
static int WhenFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    return (JIM_ERR);
}


Jim_Interp* interp = NULL;
static void eval(char* code) {
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
        fprintf(stderr, "%s\n", Jim_GetString(Jim_GetResult(interp), NULL));
        Jim_FreeInterp(interp);
        exit(EXIT_FAILURE);
    }
}
static void dbWriteToPdf(Db* db) {
    char code[500];
    snprintf(code, 500,
             "source db.tcl; "
             "dbWriteToPdf {(Db*) %p} db.pdf", db);
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

    usleep(1000000);

    printf("main: Done!\n");

    pthread_mutex_lock(&dbMutex);
    dbWriteToPdf(db);
    pthread_mutex_unlock(&dbMutex);
}
