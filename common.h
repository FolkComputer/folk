#ifndef COMMON_H
#define COMMON_H

#include "workqueue.h"

typedef struct ThreadControlBlock {
    int index;
    pid_t _Atomic tid;

    WorkQueue* workQueue;

    // Used for diagnostics/profiling.
    WorkQueueItem currentItem;
    pthread_mutex_t currentItemMutex;

    // Current match being constructed (if applicable).
    Match* currentMatch;
} ThreadControlBlock;

#define THREADS_MAX 100

#endif
