#include <stdio.h>
#include <stdlib.h>

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

// See: https://aturon.github.io/blog/2015/08/27/epoch/#epoch-based-reclamation

#define EPOCH_GARBAGE_MAX 32768

static _Atomic int epochGlobalCounter;
typedef struct EpochGlobalGarbage {
    void* _Atomic garbage[EPOCH_GARBAGE_MAX];
    _Atomic int garbageNextIdx;
} EpochGlobalGarbage;
static EpochGlobalGarbage epochGlobalGarbage[3];

// Thread-specific state that needs to also be readable from the
// collector thread.
typedef struct EpochThreadState {
    _Atomic bool active;
    _Atomic int epochCounter;
} EpochThreadState;

#define EPOCH_THREADS_MAX 100
static EpochThreadState threadStates[EPOCH_THREADS_MAX];
static _Atomic int threadCount;

static __thread EpochThreadState *threadState;

// Thread-local state that no one else reads.

#define FREES_MAX 1024
static __thread void *frees[FREES_MAX];
static __thread int freesNextIdx = 0;

#define ALLOCS_MAX 1024
static __thread void *allocs[ALLOCS_MAX];
static __thread int allocsNextIdx = 0;

void epochThreadInit() {
    int threadIdx = threadCount++;
    fprintf(stderr, "thread %d: epochThreadInit\n", threadIdx);
    threadState = &threadStates[threadIdx];
    threadState->active = false;
    threadState->epochCounter = 0;
}

void epochBegin() {
    threadState->active = true;
    threadState->epochCounter = epochGlobalCounter;
}

void *epochAlloc(size_t sz) {
    int idx = allocsNextIdx++;
    if (idx >= ALLOCS_MAX) {
        fprintf(stderr, "epochAlloc: ran out of alloc slots\n");
        exit(1);
    }
    allocs[idx] = tmalloc(sz);
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
void epochReset() {
    // Free every allocation we've done this epoch.
    for (int i = 0; i < allocsNextIdx; i++) {
        tfree(allocs[i]);
    }
    allocsNextIdx = 0;

    // Throw away the whole frees list so it doesn't actually get
    // retired by the collector later.
    freesNextIdx = 0;
}
static void epochRetireAll() {
    // Move all frees to global garbage list.
    EpochGlobalGarbage *g = &epochGlobalGarbage[epochGlobalCounter % 3];
    for (int i = 0; i < freesNextIdx; i++) {
        // TODO: Can we batch this operation?
        int gidx = g->garbageNextIdx++;
        if (gidx >= EPOCH_GARBAGE_MAX) {
            fprintf(stderr, "epochRetireAll: ran out of global garbage slots (epoch %d)\n",
                    epochGlobalCounter);
            for (int i = 0; i < threadCount; i++) {
                EpochThreadState *st = &threadStates[i];
                fprintf(stderr, "  thread %d: epoch %d\n",
                        i, st->epochCounter);
            }
            exit(1);
        }
        g->garbage[gidx] = frees[i];
    }
    freesNextIdx = 0;
}

void epochEnd() {
    allocsNextIdx = 0;
    epochRetireAll();

    threadState->active = false;
}

// This should be called from just one thread ever.
void epochGlobalCollect() {
    for (int i = 0; i < threadCount; i++) {
        EpochThreadState *st = &threadStates[i];
        if (st->active && st->epochCounter != epochGlobalCounter) {
            return;
        }
    }
    int freeableEpoch = (epochGlobalCounter++) - 1;
    // Free garbage from 2 epochs ago, which is guaranteed to be
    // untouchable by any active thread:
    EpochGlobalGarbage *g = &epochGlobalGarbage[freeableEpoch % 3];
    int garbageCount = g->garbageNextIdx;
    for (int i = 0; i < garbageCount; i++) {
#ifdef TRACY_ENABLE
        TracyCFree(g->garbage[i]);
#endif
        free(g->garbage[i]);
    }
    g->garbageNextIdx = 0;
}
