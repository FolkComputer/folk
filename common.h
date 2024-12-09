#ifndef COMMON_H
#define COMMON_H

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include "workqueue.h"

typedef struct Mutex {
    TracyCLockCtx tracyCtx;
    pthread_mutex_t mutex;
} Mutex;

typedef struct ThreadControlBlock {
    int index;
    pid_t _Atomic tid;

    WorkQueue* workQueue;

    // Used for (serially) and for profiling & diagnostics.
    WorkQueueItem currentItem;
    Mutex currentItemMutex;

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

#define mutexInit(m) do {                               \
        pthread_mutex_init(&((m)->mutex), NULL);        \
        TracyCLockAnnounce((m)->tracyCtx);              \
    } while (0)

#define mutexLock(m) do {            \
        TracyCLockBeforeLock((m)->tracyCtx);    \
        pthread_mutex_lock(&((m)->mutex));      \
        TracyCLockAfterLock((m)->tracyCtx);     \
    } while (0)

#define mutexUnlock(m) do {                     \
        pthread_mutex_unlock(&((m)->mutex));    \
        TracyCLockAfterUnlock((m)->tracyCtx);   \
    } while (0)

#endif
