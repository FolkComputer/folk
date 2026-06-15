#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#ifdef TRACY_ENABLE

#include <string.h>
inline void *tmalloc(size_t sz) {
    void *ptr = malloc(sz);
    TracyCAllocS(ptr, sz, 4);
    return ptr;
}
inline void *tcalloc(size_t s1, size_t s2) {
    void *ptr = calloc(s1, s2);
    TracyCAllocS(ptr, s1 * s2, 4);
    return ptr;
}
inline char *tstrdup(const char *s0) {
    int sz = strlen(s0) + 1;
    char *s = tmalloc(sz);
    memcpy(s, s0, sz);
    return s;
}
inline void tfree(void *ptr) {
    TracyCFreeS(ptr, 4);
    free(ptr);
}

#else

#define tmalloc malloc
#define tcalloc calloc
#define tstrdup strdup
#define tfree free

#endif

#include "epoch.h"
#include "vendor/jimtcl/jim.h"

// See: https://aturon.github.io/blog/2015/08/27/epoch/#epoch-based-reclamation

#define EPOCH_GARBAGE_MAX 1048576

static _Atomic int epochGlobalCounter;
typedef struct EpochGlobalGarbage {
    void* _Atomic garbage[EPOCH_GARBAGE_MAX];
    _Atomic int garbageNextIdx;
} EpochGlobalGarbage;
static EpochGlobalGarbage epochGlobalGarbage[3];

typedef struct EpochGlobalDecrRefs {
    Jim_Obj* _Atomic decrRefs[EPOCH_GARBAGE_MAX];
    _Atomic int decrRefsNextIdx;
} EpochGlobalDecrRefs;
static EpochGlobalDecrRefs epochGlobalDecrRefs[3];

// Thread-specific state that needs to also be readable from the
// collector thread.
typedef struct EpochThreadState {
    _Atomic bool inUse;

    _Atomic bool active;
    _Atomic int epochCounter;
} EpochThreadState;

#define EPOCH_THREADS_MAX 100
static EpochThreadState threadStates[EPOCH_THREADS_MAX];

static __thread EpochThreadState *threadState;

// Thread-local state that no one else reads.

#define FREES_MAX 1024
static __thread void *frees[FREES_MAX];
static __thread int freesNextIdx;

#define ALLOCS_MAX 1024
static __thread void *allocs[ALLOCS_MAX];
static __thread int allocsNextIdx;

#define DECR_REFS_MAX 1024
static __thread Jim_Obj *decrRefs[DECR_REFS_MAX];
static __thread int decrRefsNextIdx;

void epochThreadInit() {
    int threadIdx = -1;
    for (int i = 0; i < EPOCH_THREADS_MAX; i++) {
        bool notInUse = false;
        if (atomic_compare_exchange_weak(&threadStates[i].inUse, &notInUse, true)) {
            threadIdx = i;
            break;
        }
    }
    if (threadIdx == -1) {
        fprintf(stderr, "epochThreadInit: no more thread slots\n");
        exit(1);
    }

    /* fprintf(stderr, "thread %d: epochThreadInit\n", threadIdx); */
    threadState = &threadStates[threadIdx];
    threadState->inUse = true;
    threadState->active = false;
    threadState->epochCounter = 0;

    freesNextIdx = 0;
    allocsNextIdx = 0;
    decrRefsNextIdx = 0;
}
void epochThreadDestroy() {
    threadState->inUse = false;
}

#ifdef TRACY_ENABLE
static __thread TracyCZoneCtx __zoneCtx;
#endif
void epochBegin() {
#ifdef TRACY_ENABLE
    TracyCZoneNS(ctx, "Epoch", 3, 1); __zoneCtx = ctx;
#endif

    threadState->active = true;
    threadState->epochCounter = epochGlobalCounter;
}

void *epochAlloc(size_t sz) {
    int idx = allocsNextIdx++;
    if (idx >= ALLOCS_MAX) {
        fprintf(stderr, "epochAlloc: ran out of alloc slots\n");
        exit(1);
    }
    allocs[idx] = malloc(sz);
    // TracyCAlloc(allocs[idx], sz);
    return allocs[idx];
}
void epochFree(void *ptr) {
    int idx = freesNextIdx++;
    if (idx >= FREES_MAX) {
        fprintf(stderr, "epochFree: ran out of free slots\n");
        exit(1);
    }
    frees[idx] = ptr;
}
void epochDecrRef(Jim_Obj *obj) {
    int idx = decrRefsNextIdx++;
    if (idx >= DECR_REFS_MAX) {
        fprintf(stderr, "epochDecrRef: ran out of decr ref slots\n");
        exit(1);
    }
    decrRefs[idx] = obj;
}
void epochReset() {
    // Free every allocation we've done this epoch.
    for (int i = 0; i < allocsNextIdx; i++) {
        /* TracyCFree(allocs[i]); */
        free(allocs[i]);
    }
    allocsNextIdx = 0;

    // Throw away the whole frees list so it doesn't actually get
    // retired by the collector later.
    freesNextIdx = 0;

    // Throw away deferred decrements — on retry, trieRemoveImpl will
    // call epochDecrRef again for the same keys.
    decrRefsNextIdx = 0;
}
static void epochRetireAll() {
    // Move all frees to global garbage list.
    EpochGlobalGarbage *g = &epochGlobalGarbage[epochGlobalCounter % 3];
    for (int i = 0; i < freesNextIdx; i++) {
        // TODO: Can we batch this operation?
        int gidx = g->garbageNextIdx++;
        if (gidx >= EPOCH_GARBAGE_MAX) {
            fprintf(stderr, "epochRetireAll: ran out of global garbage slots (epoch %d).\n"
                    "(This probably means that something is blocking the sysmon thread.)\n",
                    epochGlobalCounter);
            for (int i = 0; i < EPOCH_THREADS_MAX; i++) {
                EpochThreadState *st = &threadStates[i];
                if (!st->inUse) { continue; }
                fprintf(stderr, "  thread %d: epoch %d\n",
                        i, st->epochCounter);
            }
            exit(1);
        }
        g->garbage[gidx] = frees[i];
    }
    freesNextIdx = 0;

    // Move all deferred Jim_DecrRefCount calls to global list.
    EpochGlobalDecrRefs *d = &epochGlobalDecrRefs[epochGlobalCounter % 3];
    for (int i = 0; i < decrRefsNextIdx; i++) {
        int didx = d->decrRefsNextIdx++;
        if (didx >= EPOCH_GARBAGE_MAX) {
            fprintf(stderr, "epochRetireAll: ran out of global decrRefs slots (epoch %d).\n",
                    epochGlobalCounter);
            exit(1);
        }
        d->decrRefs[didx] = decrRefs[i];
    }
    decrRefsNextIdx = 0;
}

void epochEnd() {
    allocsNextIdx = 0;
    epochRetireAll();

    threadState->active = false;
#ifdef TRACY_ENABLE
    TracyCZoneEnd(__zoneCtx);
#endif
}

// This should be called from just one thread ever.
void epochGlobalCollect() {
    for (int i = 0; i < EPOCH_THREADS_MAX; i++) {
        EpochThreadState *st = &threadStates[i];
        if (!st->inUse) { continue; }

        if (st->active && st->epochCounter != epochGlobalCounter) {
            return;
        }
    }
    int freeableEpoch = (epochGlobalCounter++) - 1;
    // Free garbage from 2 epochs ago, which is guaranteed to be
    // untouchable by any active thread:
    EpochGlobalGarbage *g = &epochGlobalGarbage[((freeableEpoch % 3) + 3) % 3];
    int garbageCount = g->garbageNextIdx;
    for (int i = 0; i < garbageCount; i++) {
#ifdef TRACY_ENABLE
        // TracyCFree(g->garbage[i]);
#endif
        free(g->garbage[i]);
    }
    g->garbageNextIdx = 0;

    // Process deferred Jim_DecrRefCount calls from 2 epochs ago.
    // At this point no reader thread is in that epoch, so keys are safe to release.
    EpochGlobalDecrRefs *d = &epochGlobalDecrRefs[((freeableEpoch % 3) + 3) % 3];
    int decrCount = d->decrRefsNextIdx;
    for (int i = 0; i < decrCount; i++) {
        Jim_DecrRefCount(d->decrRefs[i]);
    }
    d->decrRefsNextIdx = 0;
}
