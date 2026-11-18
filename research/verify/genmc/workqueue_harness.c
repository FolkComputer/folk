// GenMC harness for the work-stealing deque in workqueue.c.
//
// ThreadSanitizer reports a data race between the thread that pushes a
// work item and the thread that steals it, on the item itself and on
// everything it points to. The deque passes items from one to the other
// with atomic_thread_fence, which ThreadSanitizer does not model. GenMC
// does (it checks every execution allowed by the RC11 memory model), so
// this harness asks it the question directly: with one owner pushing and
// taking and two thieves stealing, is there a race on an item, and is
// every item consumed exactly once?
//
//   genmc -- -I../../.. -I../../../vendor/jimtcl workqueue_harness.c
//
// Expected: "No errors were detected."

#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
#include <stdlib.h>

// GenMC ships its own minimal C library headers, which lack ssize_t and
// calloc. workqueue.c depends on calloc's zeroing (a thief holding a stale
// index can read a slot of a freshly grown array that was never written,
// and must find NULL there), so zero the block here, with word-sized
// atomic stores because every field of the deque is a word-sized atomic.
typedef long ssize_t;
static void* zeroedAlloc(size_t count, size_t size) {
    size_t words = (count * size) / sizeof(size_t);
    _Atomic(size_t)* p = malloc(words * sizeof(size_t));
    for (size_t i = 0; i < words; i++) {
        atomic_store_explicit(&p[i], 0, memory_order_relaxed);
    }
    return p;
}
#define calloc zeroedAlloc

#include "../../../workqueue.c"

#define ITEMS 3

static WorkQueue* q;
// consumed[i] counts how many times item i came out of the deque.
static atomic_int consumed[ITEMS];

static void consume(WorkQueueItem item) {
    if (item.op == NONE) { return; }
    // Reading the payload is what ThreadSanitizer flags.
    int id = item.assert.sourceLineNumber;
    atomic_fetch_add(&consumed[id], 1);
}

static void* owner(void* arg) {
    // The array starts with room for two items, so the third push also
    // exercises workQueueResize.
    for (int i = 0; i < ITEMS; i++) {
        workQueuePush(q, (WorkQueueItem) {
            .op = ASSERT, .assert = { .sourceLineNumber = i }
        });
    }
    for (int i = 0; i < ITEMS; i++) {
        consume(workQueueTake(q));
    }
    return NULL;
}

static void* thief(void* arg) {
    consume(workQueueSteal(q));
    return NULL;
}

int main() {
    q = workQueueNew();

    pthread_t o, t1, t2;
    pthread_create(&o, NULL, owner, NULL);
    pthread_create(&t1, NULL, thief, NULL);
    pthread_create(&t2, NULL, thief, NULL);
    pthread_join(o, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    // The owner drains what the thieves left, so everything is consumed,
    // and nothing twice.
    for (int i = 0; i < ITEMS; i++) {
        assert(atomic_load(&consumed[i]) == 1);
    }
    return 0;
}
