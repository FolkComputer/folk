#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "db.h"
#include "trie.h"

typedef struct WorkQueue WorkQueue;
typedef enum WorkQueueOp { NONE, ASSERT, RETRACT, HOLD, SAY, RUN } WorkQueueOp;
typedef struct WorkQueueItem {
    WorkQueueOp op;
    int seq;

    // Thread constraint: if thread is >= 0, then this work item will
    // only be processed on the thread with that thread ID.
    int thread;

    // Clause pointers are the responsibility of the user of the
    // workqueue to keep alive (and to free once a work item is
    // processed). The workqueue does not itself copy or own or free
    // the Clause* you give it.
    union {
        struct { Clause* clause; } assert;
        struct { Clause* pattern; } retract;
        struct {
            // Caller is also responsible for keeping key alive & for
            // freeing it on dequeue.
            const char* key;
            int64_t version;

            Clause* clause;
        } hold;
        struct {
            // This MatchRef may be invalidated while this Say is
            // still in the workqueue -- we detect that when we
            // process the Say and invalidate the Say in that case.
            MatchRef parent;

            Clause* clause;
        } say;
        struct {
            // The StatementRefs may be invalidated while this Run is
            // still in the workqueue -- if either is invalidated,
            // then the Run is invalidated.
            StatementRef when;
            Clause* whenPattern;
            StatementRef stmt;
        } run;
    };
} WorkQueueItem;

WorkQueue* workQueueNew();

// Adds an item to work queue.
void workQueuePush(WorkQueue* q, WorkQueueItem item);

// Removes the highest-priority item from work queue:
WorkQueueItem workQueuePop(WorkQueue* q);

#endif
