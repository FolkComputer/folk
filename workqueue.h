#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "db.h"
#include "trie.h"

typedef enum WorkQueueOp { NONE, ASSERT, RETRACT, HOLD, SAY, RUN, REMOVE_PARENT } WorkQueueOp;
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
        struct { StatementRef stmt; } removeParent;
    };
} WorkQueueItem;

typedef struct WorkQueue WorkQueue;

WorkQueue* workQueueNew();

// Removes the top item from work queue:
WorkQueueItem* workQueueTake(WorkQueue* q);

// Adds an item to the top of work queue:
void workQueuePush(WorkQueue* q, WorkQueueItem* item);

// Removes the bottom item from work queue:
WorkQueueItem* workQueueSteal(WorkQueue* q);

#endif
