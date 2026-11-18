// GenMC harness for GenRc, the generation + reference count word that
// guards every Statement and Match slot in db.c.
//
// The code under test is cut out of db.c by the Makefile (genrc_extract.h),
// so this checks the real genRcAcquire / genRcRelease / genRcMarkAsDead.
//
// One object, alive, at generation 0. A reader acquires it through a weak
// reference, uses it and releases it. A remover acquires it, marks it dead
// and releases it. A late reader tries the same stale reference. Checked
// over every interleaving RC11 allows:
//   - the object is destroyed exactly once,
//   - never while someone who acquired it is still using it,
//   - and a reference from before the destruction never acquires again.
//
//   genmc -- genrc_harness.c
//
// Expected: "No errors were detected."

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <assert.h>

#include "genrc_extract.h"

static _Atomic GenRc slot;
static atomic_int destroyed;    // how many times the slot was destroyed
static atomic_int users;        // threads between acquire and release

static void release(void) {
    atomic_fetch_sub(&users, 1);
    if (genRcRelease(&slot)) {
        // Last pointer to a dead object: this is where statementDestroy
        // or matchDestroy runs.
        assert(atomic_load(&users) == 0);
        atomic_fetch_add(&destroyed, 1);
    }
}

static void* reader(void* arg) {
    if (genRcAcquire(&slot, 0)) {
        atomic_fetch_add(&users, 1);
        assert(atomic_load(&destroyed) == 0);   // still ours to read
        release();
    }
    return NULL;
}

static void* remover(void* arg) {
    if (genRcAcquire(&slot, 0)) {
        atomic_fetch_add(&users, 1);
        genRcMarkAsDead(&slot);
        release();
    }
    return NULL;
}

int main() {
    GenRc initial = { .rc = 0, .gen = 0, .alive = true };
    atomic_store(&slot, initial);

    pthread_t r1, r2, rm;
    pthread_create(&r1, NULL, reader, NULL);
    pthread_create(&rm, NULL, remover, NULL);
    pthread_create(&r2, NULL, reader, NULL);
    pthread_join(r1, NULL);
    pthread_join(rm, NULL);
    pthread_join(r2, NULL);

    assert(atomic_load(&destroyed) == 1);
    // The generation moved on, so the old reference is dead for good.
    assert(!genRcAcquire(&slot, 0));
    return 0;
}
