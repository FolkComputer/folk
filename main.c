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

static void dbWriteToPdf(Db* db) {
    Jim_Interp* interp;
    interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    char code[500];
    snprintf(code, 500,
             "source db.tcl; "
             "dbWriteToPdf {(Db*) %p} db.pdf", db);
    Jim_Eval(interp, code);
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
    pushAssert("C is a programming language");
    pushAssert("Java is a programming language");
    pushAssert("JavaScript is a programming language");

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


/* Folk { */
/*     Claim Mac is an OS */
/*     Claim Linux is an OS */
/*     Claim Windows is an OS */

/*     When /x/ is an OS { */
/*         sleep 3 */
/*         Claim $x really is an OS */
/*     } */

/*     When Mac really is an OS \& */
/*          Linux really is an OS \& */
/*          Windows really is an OS { */
/*         puts "Passed" */
/*         exit 0 */
/*     } */
/* } */
