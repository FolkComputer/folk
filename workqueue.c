#include <stdlib.h>
#include <stdio.h>
#include <pqueue.h>

#include "workqueue.h"

typedef struct WorkQueue {
    pqueue_t q;
} WorkQueue;

// TODO: Lock the workQueue.
// TODO: Allocate in shared memory.

// Implementations of priority queue operations:

int workQueueItemCompare(pqueue_pri_t next, pqueue_pri_t curr) {
    return next < curr;
}
pqueue_pri_t workQueueItemGetPriority(void* a) {
    WorkQueueItem* item = a;
    switch (item->op) {
    case NONE: return 0;
    case ASSERT:
    case RETRACT: return 80000 - item->seq;
    case SAY: return 80000 + item->seq;
    }
    return 0;
}
void workQueueItemSetPriority(void* a, pqueue_pri_t pri) {}
size_t workQueueItemGetPosition(void* a) { return 0; }
void workQueueItemSetPosition(void* a, size_t pos) {}

WorkQueue* workQueueNew() {
    return (WorkQueue*) pqueue_init(16384,
                                    workQueueItemCompare,
                                    workQueueItemGetPriority,
                                    workQueueItemSetPriority,
                                    workQueueItemGetPosition,
                                    workQueueItemSetPosition);
}

void workQueuePush(WorkQueue* q, WorkQueueItem item) {
    WorkQueueItem* ptr = malloc(sizeof(item));
    *ptr = item; // ptr->seq = seq++;
    pqueue_insert(&q->q, ptr);
}
WorkQueueItem workQueuePop(WorkQueue* q) {
    WorkQueueItem* itemPtr = pqueue_pop(&q->q);
    if (itemPtr == NULL) {
        return (WorkQueueItem) { .op = NONE };
    }
    WorkQueueItem item = *itemPtr; free(itemPtr);
    return item;
}
