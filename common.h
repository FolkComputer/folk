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

    // Used for managing the threadpool.
    clockid_t clockid;
    int64_t _Atomic currentItemStartTimestamp;

    // Current match being constructed (if applicable).
    Match* currentMatch;
} ThreadControlBlock;

#define THREADS_MAX 100

static inline int64_t timestamp_get(clockid_t clk_id) {
    // Returns timestamp in nanoseconds.
    struct timespec ts;
    if (clock_gettime(clk_id, &ts)) {
        perror("can't even get the time :'-(");
    }
    return (int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec;
}

#endif
