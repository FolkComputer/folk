// stbds_race.c -- shows that a stb_ds hash-map lookup is not read-only.
//
// output-redirection.c and block-stats.c look up a string key with
// shgetp_null() while holding a pthread *read* lock. shgetp_null stores
// the index it found in the map's header (stbds_temp) and then reads the
// header again to form the result, so two readers can exchange results.
//
// Two threads each look up their own key in a two-entry map, under a read
// lock, exactly as the runtime does, and count how often they are handed
// the other thread's entry.
//
// stb_ds is compiled separately here, as it is in Folk (folk.c holds the
// implementation; block-stats.c and output-redirection.c only see the
// header). With the implementation in the same file the compiler can keep
// the index in a register and the swap cannot be observed.
//
//   make -C research/verify stbds-race

#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "vendor/stb_ds.h"

typedef struct { char *key; int owner; } Entry;
static Entry *table = NULL;
static pthread_rwlock_t lock = PTHREAD_RWLOCK_INITIALIZER;

#define LOOKUPS 5000000

static void *reader(void *arg) {
    int me = (int)(long) arg % 2;
    const char *key = me == 0 ? "program-a.folk" : "program-b.folk";
    long wrong = 0;
    for (long i = 0; i < LOOKUPS; i++) {
        pthread_rwlock_rdlock(&lock);
        Entry *e = shgetp_null(table, key);
        if (e == NULL || e->owner != me) { wrong++; }
        pthread_rwlock_unlock(&lock);
    }
    return (void *) wrong;
}

int main(void) {
    sh_new_arena(table);
    Entry a = { .key = "program-a.folk", .owner = 0 };
    Entry b = { .key = "program-b.folk", .owner = 1 };
    shputs(table, a);
    shputs(table, b);

    pthread_t t[8];
    for (long i = 0; i < 8; i++) { pthread_create(&t[i], NULL, reader, (void *) i); }
    long wrong = 0;
    for (int i = 0; i < 8; i++) {
        void *result; pthread_join(t[i], &result);
        wrong += (long) result;
    }
    printf("%ld lookups under a read lock, %ld returned the other thread's entry\n",
           8L * LOOKUPS, wrong);
    return 0;
}
