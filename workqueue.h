#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "db.h"
#include "trie.h"

typedef struct WorkQueue WorkQueue;
typedef enum WorkQueueOp { NONE, ASSERT, RETRACT, SAY } WorkQueueOp;
typedef struct WorkQueueItem {
    WorkQueueOp op;
    int seq;

    int thread;

    union {
        struct { Clause* clause; } assert;
        struct { Clause* pattern; } retract;
        struct {
            Match* parent;
            Clause* clause;
        } say;
    };
} WorkQueueItem;

WorkQueue* workQueueNew();

// Adds an item to work queue:
void workQueuePush(WorkQueue* q, WorkQueueItem item);

// Removes the highest-priority item from work queue:
WorkQueueItem workQueuePop(WorkQueue* q);

#endif
