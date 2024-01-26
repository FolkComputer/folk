#include <stdlib.h>
#include <stdio.h>
#include <pqueue.h>

#include "workqueue.h"

typedef struct WorkQueue {
    pqueue_t q;
} WorkQueue;
typedef struct WorkQueueEntry {
    WorkQueueOp op;
    int seq;

    union {
        struct { Clause* clause; } assert;
        struct { Clause* pattern; } retract;
    };
} WorkQueueEntry;

// TODO: Lock the workQueue.
// TODO: Allocate in shared memory.

// Implementations of priority queue operations:

int workQueueEntryCompare(pqueue_pri_t next, pqueue_pri_t curr) {
    return next < curr;
}
pqueue_pri_t workQueueEntryGetPriority(void* a) {
    WorkQueueEntry* entry = a;
    switch (entry->op) {
    case NONE: return 0;
    case ASSERT:
    case RETRACT: return 80000 - entry->seq;
    }
    return 0;
}
void workQueueEntrySetPriority(void* a, pqueue_pri_t pri) {}
size_t workQueueEntryGetPosition(void* a) { return 0; }
void workQueueEntrySetPosition(void* a, size_t pos) {}

WorkQueue* workQueueNew() {
    // TODO: How do I fix all these function addresses?
    printf("workQueueNew\n");
    printf("workQueueEntryCompare: %p\n", workQueueEntryCompare);
    printf("workQueueEntryGetPriority: %p\n", workQueueEntryGetPriority);
    printf("workQueueEntrySetPriority: %p\n", workQueueEntrySetPriority);
    printf("workQueueEntryGetPosition: %p\n", workQueueEntryGetPosition);
    printf("workQueueEntrySetPosition: %p\n", workQueueEntrySetPosition);
    return (WorkQueue*) pqueue_init(16384,
                                    workQueueEntryCompare,
                                    workQueueEntryGetPriority,
                                    workQueueEntrySetPriority,
                                    workQueueEntryGetPosition,
                                    workQueueEntrySetPosition);
}

int main() {
    workQueueNew();
}
