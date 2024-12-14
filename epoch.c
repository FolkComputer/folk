#include <stdio.h>
#include <stdlib.h>

#include "epoch.h"

// See: https://aturon.github.io/blog/2015/08/27/epoch/#epoch-based-reclamation

#define EPOCH_GARBAGE_MAX (1024*1024)

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
#define MARKS_MAX 1024
static __thread void *marks[MARKS_MAX];
static __thread int marksNextIdx = 0;

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

void epochMark(void *ptr) {
    int idx = marksNextIdx++;
    if (idx >= MARKS_MAX) {
        fprintf(stderr, "epochMark: ran out of mark slots\n");
        exit(1);
    }
    marks[idx] = ptr;
}
void epochUnmarkAll() { marksNextIdx = 0; }
#include <pthread.h>
void epochRetireAll() {
    // Move all to global garbage list.
    EpochGlobalGarbage *g = &epochGlobalGarbage[epochGlobalCounter % 3];
    for (int i = 0; i < marksNextIdx; i++) {
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
        g->garbage[gidx] = marks[i];
    }
    marksNextIdx = 0;
}

void epochEnd() {
    threadState->active = false;
}

// This should be called from just one thread ever.
void epochCollect() {
    for (int i = 0; i < threadCount; i++) {
        EpochThreadState *st = &threadStates[i];
        if (st->epochCounter != epochGlobalCounter) {
            return;
        }
    }
    int freeableEpoch = (epochGlobalCounter++) - 1;
    // Free garbage from 2 epochs ago, which is guaranteed to be
    // untouchable by any active thread:
    EpochGlobalGarbage *g = &epochGlobalGarbage[freeableEpoch % 3];
    for (int i = 0; i < g->garbageNextIdx; i++) {
        free(g->garbage[i]);
    }
    g->garbageNextIdx = 0;
}
