#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "db.h"
#include "trie.h"

typedef struct WorkQueue WorkQueue;
typedef enum WorkQueueOp { NONE, ASSERT, RETRACT, HOLD, SAY } WorkQueueOp;
typedef struct WorkQueueItem {
    WorkQueueOp op;
    int seq;

    // Thread constraint: if thread is >= 0, then this work item will
    // only be processed on the thread with that thread ID.
    int thread;

    // Clause pointers are the responsibility of the user of the
    // workqueue to keep alive. The workqueue does not copy or own or
    // free the Clause* you give it.
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
            Match* parent;
            Clause* clause;
        } say;
    };
} WorkQueueItem;

WorkQueue* workQueueNew();

// Adds an item to work queue.
void workQueuePush(WorkQueue* q, WorkQueueItem item);

// Removes the highest-priority item from work queue:
WorkQueueItem workQueuePop(WorkQueue* q);

#endif
