#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>

#include "vendor/stb_ds.h"

#include <libzicl.h>
#include "zicl-helpers.h"

#include "common.h"
#include "block-stats.h"

// Running EWMA of block eval runtime per filename:lineno.
// rwlock: rlock for updates to existing entries (ewma/count updated with
// relaxed atomics), wlock only when inserting a new entry.
typedef struct {
    char *key;       // stb_ds string hashmap key ("filename:lineno")
    uint64_t count;
    double ewma_ns;
} BlockStat;
static BlockStat *blockStats = NULL;
static pthread_rwlock_t blockStatsLock = PTHREAD_RWLOCK_INITIALIZER;

void blockStatsInit(void) {
    sh_new_arena(blockStats);
}

void blockStatsUpdate(const char *sourceFileName, int sourceLineNumber,
                      int64_t elapsed_ns) {
    char key[1024];
    if (snprintf(key, sizeof(key), "%s:%d", sourceFileName, sourceLineNumber)
            >= (int)sizeof(key)) return;

    // Fast path: entry already exists — update under rlock with relaxed atomics.
    pthread_rwlock_rdlock(&blockStatsLock);
    BlockStat *e = shgetp_null(blockStats, key);
    if (e != NULL) {
        __atomic_fetch_add(&e->count, 1, __ATOMIC_RELAXED);
        double prev, next;
        __atomic_load(&e->ewma_ns, &prev, __ATOMIC_RELAXED);
        next = 0.1 * elapsed_ns + 0.9 * prev;
        __atomic_store(&e->ewma_ns, &next, __ATOMIC_RELAXED);
        pthread_rwlock_unlock(&blockStatsLock);
        return;
    }
    pthread_rwlock_unlock(&blockStatsLock);

    // Slow path: new entry — acquire wlock, recheck, insert.
    pthread_rwlock_wrlock(&blockStatsLock);
    if (shgetp_null(blockStats, key) == NULL) {
        BlockStat new_entry = { .key = (char *)key, .count = 0, .ewma_ns = 0.0 };
        shputs(blockStats, new_entry);
    }
    e = shgetp_null(blockStats, key);
    e->count++;
    e->ewma_ns = e->count == 1 ? (double)elapsed_ns
                               : 0.1 * elapsed_ns + 0.9 * e->ewma_ns;
    pthread_rwlock_unlock(&blockStatsLock);
}

int __blockRuntimeStatsFunc(Zicl_Interp *interp, int argc, Zicl_Shim *argv) {
    (void)argc;
    (void)argv;
    Zicl_List* result = ziclNewList(NULL, 0);
    pthread_rwlock_rdlock(&blockStatsLock);
    for (int i = 0; i < shlen(blockStats); i++) {
        Zicl_Val items[3] = {
            ziclNewString(blockStats[i].key, -1),
            Zicl_NewDouble(blockStats[i].ewma_ns),
            Zicl_NewLong(blockStats[i].count),
        };
        defer { Zicl_DropRefArrayItems(items, sizeof(items)/sizeof(Zicl_Val)); };
        Zicl_Val entry = Zicl_BoxList(ziclNewList(items, 3));
        defer { Zicl_DropRef(entry); }
        ziclListAppend(result, entry);
    }
    pthread_rwlock_unlock(&blockStatsLock);
    Zicl_SetResultOwning(interp, Zicl_BoxList(result));
    return ZICL_OK;
}
