#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "trie.h"

typedef struct WorkQueue WorkQueue;
typedef enum WorkQueueOp { NONE, ASSERT, RETRACT } WorkQueueOp;
typedef struct WorkQueueItem {
    WorkQueueOp op;
    int seq;

    union {
        struct { Clause* clause; } assert;
        struct { Clause* pattern; } retract;
    };
} WorkQueueItem;

WorkQueue* workQueueNew();

// These add entries to work queue:
void workQueuePush(WorkQueue* q, WorkQueueItem item);

// Removes an item from work queue:
WorkQueueItem workQueuePop(WorkQueue* q);

#endif
