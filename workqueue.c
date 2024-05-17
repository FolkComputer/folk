#include <stdlib.h>
#include <stdatomic.h>

#include "workqueue.h"

// https://fzn.fr/readings/ppopp13.pdf
// http://plrg.eecs.uci.edu/git/?p=model-checker-benchmarks.git;a=tree;f=chase-lev-deque-bugfix;h=79e573fe89144e2a7fe1bc801083e3c35e1e5f16;hb=HEAD

typedef struct WorkQueueArray {
    size_t _Atomic size;
    WorkQueueItem* _Atomic buffer[];
} WorkQueueArray;

typedef struct WorkQueue {
    size_t _Atomic top;
    size_t _Atomic bottom;
    WorkQueueArray* _Atomic array;
} WorkQueue;

WorkQueue* workQueueNew() {
    WorkQueue* q = (WorkQueue*) calloc(1, sizeof(WorkQueue));
    // default size of WorkQueueArray is 2.
    WorkQueueArray* a = (WorkQueueArray*) calloc(1, sizeof(WorkQueueArray) + 2*sizeof(WorkQueueItem*));
    atomic_store_explicit(&q->array, a, memory_order_relaxed);
    atomic_store_explicit(&q->top, 0, memory_order_relaxed);
    atomic_store_explicit(&q->bottom, 0, memory_order_relaxed);
    atomic_store_explicit(&a->size, 2, memory_order_relaxed);
    return q;
}

WorkQueueItem* workQueueTake(WorkQueue* q) {
    size_t b = atomic_load_explicit(&q->bottom, memory_order_relaxed) - 1;
    WorkQueueArray* a = (WorkQueueArray*) atomic_load_explicit(&q->array, memory_order_relaxed);
    atomic_store_explicit(&q->bottom, b, memory_order_relaxed);
    atomic_thread_fence(memory_order_seq_cst);
    size_t t = atomic_load_explicit(&q->top, memory_order_relaxed);
    WorkQueueItem* x;
    if (t <= b) {
        /* Non-empty queue. */
        x = atomic_load_explicit(&a->buffer[b %
                                            atomic_load_explicit(&a->size, memory_order_relaxed)],
                                 memory_order_relaxed);
        if (t == b) {
            /* Single last element in queue. */
            if (!atomic_compare_exchange_strong_explicit(&q->top, &t, t + 1,
                                                         memory_order_seq_cst, memory_order_relaxed)) {
                /* Failed race. */
                x = NULL;
            }
            atomic_store_explicit(&q->bottom, b + 1, memory_order_relaxed);
        }
    } else { /* Empty queue. */
        x = NULL;
        atomic_store_explicit(&q->bottom, b + 1, memory_order_relaxed);
    }
    return x;
}

static void workQueueResize(WorkQueue* q) {
    WorkQueueArray* a = (WorkQueueArray*) atomic_load_explicit(&q->array, memory_order_relaxed);
    size_t size = atomic_load_explicit(&a->size, memory_order_relaxed);
    size_t new_size = size << 1;
    WorkQueueArray *new_a = (WorkQueueArray*) calloc(1, new_size * sizeof(WorkQueueItem*) + sizeof(WorkQueueArray));
    size_t top = atomic_load_explicit(&q->top, memory_order_relaxed);
    size_t bottom = atomic_load_explicit(&q->bottom, memory_order_relaxed);
    atomic_store_explicit(&new_a->size, new_size, memory_order_relaxed);
    size_t i;
    for (i = top; i < bottom; i++) {
        atomic_store_explicit(&new_a->buffer[i % new_size],
                              atomic_load_explicit(&a->buffer[i % size], memory_order_relaxed),
                              memory_order_relaxed);
    }
    atomic_store_explicit(&q->array, new_a, memory_order_release);
    /* printf("resize\n"); */
}

void workQueuePush(WorkQueue* q, WorkQueueItem* x) {
    size_t b = atomic_load_explicit(&q->bottom, memory_order_relaxed);
    size_t t = atomic_load_explicit(&q->top, memory_order_acquire);
    WorkQueueArray* a = (WorkQueueArray*) atomic_load_explicit(&q->array, memory_order_relaxed);
    if (b - t > atomic_load_explicit(&a->size, memory_order_relaxed) - 1) {
        /* Full queue. */
        workQueueResize(q);
        // Bug in paper... should have next line...
        a = (WorkQueueArray*) atomic_load_explicit(&q->array, memory_order_relaxed);
    }
    atomic_store_explicit(&a->buffer[b % atomic_load_explicit(&a->size, memory_order_relaxed)],
                          x, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&q->bottom, b + 1, memory_order_relaxed);
}

WorkQueueItem* workQueueSteal(WorkQueue* q) {
    size_t t = atomic_load_explicit(&q->top, memory_order_acquire);
    atomic_thread_fence(memory_order_seq_cst);
    size_t b = atomic_load_explicit(&q->bottom, memory_order_acquire);
    WorkQueueItem* x = NULL;
    if (t < b) {
        /* Non-empty queue. */
        WorkQueueArray* a = (WorkQueueArray*) atomic_load_explicit(&q->array, memory_order_acquire);
        x = atomic_load_explicit(&a->buffer[t % atomic_load_explicit(&a->size, memory_order_relaxed)], memory_order_relaxed);
        if (!atomic_compare_exchange_strong_explicit(&q->top, &t, t + 1, memory_order_seq_cst, memory_order_relaxed)) {
            /* Failed race. */
            return NULL;
        }
    }
    return x;
}
