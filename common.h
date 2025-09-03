#ifndef COMMON_H
#define COMMON_H

#include <stdio.h>
#include <semaphore.h>
#include <errno.h>

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include "workqueue.h"

#ifdef TRACY_ENABLE
#define TracyCMessageFmt(fmt, ...) do { \
        char *msg; \
        int len = asprintf(&msg, fmt, ##__VA_ARGS__); \
        TracyCMessage(msg, len); free(msg); \
    } while (0)
#else
#define TracyCMessageFmt(fmt, ...)
#endif

#ifdef TRACY_ENABLE
typedef struct Mutex {
    TracyCLockCtx tracyCtx;
    pthread_mutex_t mutex;
} Mutex;
#else
typedef pthread_mutex_t Mutex;
#endif

typedef struct ThreadControlBlock {
    int index;
    pid_t _Atomic tid;
    pthread_t pthread;

    WorkQueue* workQueue;

    // Used for (serially) and for profiling & diagnostics.
    WorkQueueItem currentItem;
    Mutex currentItemMutex;

    // Used for managing the threadpool.
    clockid_t clockid;
    int64_t _Atomic currentItemStartTimestamp;
    bool _Atomic wasObservedAsBlocked;
    // We may deactivate (block on semaphore indefinitely) threads if
    // they got caught on some I/O-bound task and there are enough
    // non-benched threads to utilize the CPUs.
    bool _Atomic isDeactivated;
    sem_t reactivate;

    // Current match being constructed (if applicable).
    Match* currentMatch;

    // FOR DEBUGGING:
    int _Atomic _allocs;
    int _Atomic _frees;
} ThreadControlBlock;

#define THREADS_MAX 100
extern ThreadControlBlock threads[THREADS_MAX];
extern int _Atomic threadCount;
extern __thread ThreadControlBlock* self;

static inline int64_t timestamp_get(clockid_t clk_id) {
    // Returns timestamp in nanoseconds.
    struct timespec ts;
    if (clock_gettime(clk_id, &ts)) {
        perror("can't even get the time :'-(");
    }
    return (int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec;
}

#ifdef TRACY_ENABLE
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
#else
#define mutexInit(m) pthread_mutex_init(m, NULL)
#define mutexLock pthread_mutex_lock
#define mutexUnlock pthread_mutex_unlock
#endif

#endif
