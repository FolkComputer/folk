#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "db.h"
#include "trie.h"

typedef enum WorkQueueOp { NONE, ASSERT, RETRACT, HOLD, SAY, RUN, EVAL } WorkQueueOp;
typedef struct WorkQueueItem {
    WorkQueueOp op;

    // Thread constraint: if thread is >= 0, then this work item will
    // only be processed on the thread with that thread ID.
    int thread;

    // Clause pointers are the responsibility of the user of the
    // workqueue to keep alive (and to free once a work item is
    // processed). The workqueue does not itself copy or own or free
    // the Clause* you give it.
    union {
        struct {
            Clause* clause;
            // Caller is also responsible for freeing sourceFileName
            // on dequeue.
            char* sourceFileName;
            int sourceLineNumber;
        } assert;
        struct { Clause* pattern; } retract;
        struct {
            // Caller is also responsible for keeping key alive & for
            // freeing it on dequeue.
            char* key;
            int64_t version;
            int sustainMs;

            Clause* clause;

            // Caller is also responsible for freeing sourceFileName
            // on dequeue.
            char* sourceFileName;
            int sourceLineNumber;
        } hold;
        struct {
            // This MatchRef may be invalidated while this Say is
            // still in the workqueue -- we detect that when we
            // process the Say and invalidate the Say in that case.
            MatchRef parent;

            Clause* clause;

            // Caller is also responsible for freeing sourceFileName
            // on dequeue.
            char* sourceFileName;
            int sourceLineNumber;
        } say;
        struct {
            // The StatementRefs may be invalidated while this Run is
            // still in the workqueue -- if either is invalidated,
            // then the Run is invalidated.
            StatementRef when;
            Clause* whenPattern;
            StatementRef stmt;
        } run;
        struct {
            char* code;
        } eval;
    };
} WorkQueueItem;

typedef struct WorkQueue WorkQueue;

// Global module initialization. Must call first.
void workQueueInit();

// Constructs a new work queue.
WorkQueue* workQueueNew();

// Removes the bottom item from work queue:
WorkQueueItem workQueueTake(WorkQueue* q);

// Adds an item to the bottom of work queue:
void workQueuePush(WorkQueue* q, WorkQueueItem item);

// Removes the top item from work queue:
WorkQueueItem workQueueSteal(WorkQueue* q);
// Removes half the queued items from work queue, starting from the
// top item:
int workQueueStealHalf(WorkQueueItem* into, int maxn,
                       WorkQueue* q);

// Waits on global semaphore for _any_ work queue to get new item.
void workQueueAwaitAnyPush();

#endif
