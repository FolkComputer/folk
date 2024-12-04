// Inspired by Golang's sysmon. Gotta catch 'em all...

#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>

#include <time.h>
#include <sys/time.h>
#include <inttypes.h>
#include <string.h>
#include <stdatomic.h>
#ifdef __linux__
#include <sys/sysinfo.h>
#include <sys/resource.h>
#endif

#include "common.h"

// TODO: declare these in folk.h or something.
extern ThreadControlBlock threads[];
extern Db* db;
extern void trace(const char* format, ...);

extern void globalWorkQueuePush(WorkQueueItem item);

void workerSpawn();

// HACK: ncpus - 1
#define THREADS_ACTIVE_TARGET 3

#define SYSMON_TICK_MS 2

typedef struct RemoveLater {
    _Atomic StatementRef stmt;
    int64_t canRemoveAtTick;
} RemoveLater;

#define REMOVE_LATER_MAX 1000
RemoveLater removeLater[REMOVE_LATER_MAX];

int64_t _Atomic tick;

int64_t timestampAtBoot;

void sysmonInit() {
    timestampAtBoot = timestamp_get(CLOCK_MONOTONIC);
}

void sysmon() {
    /* trace("%" PRId64 "ns: Sysmon Tick", */
    /*       timestamp_get(CLOCK_MONOTONIC) - timestampAtBoot); */

    // This is the system monitoring routine that runs on every tick
    // (every few milliseconds).
    int64_t currentTick = tick;

    // First: check that we have a reasonable amount of free RAM.
#ifdef __linux__
    if (currentTick % 1000 == 0) {
        // assuming that ticks happen every 2ms, this should happen
        // every 2s.
        int freeRamMb = get_avphys_pages() * sysconf(_SC_PAGESIZE) / 1000000;
        int totalRamMb = get_phys_pages() * sysconf(_SC_PAGESIZE) / 1000000;
        // Check directly folk's own use of RAM, so we can
        // detect leaks (I think system RAM is good for killing but
        // process RAM use is better for leak diagnosis).
        struct rusage ru; getrusage(RUSAGE_SELF, &ru);
        fprintf(stderr, "Check avail system RAM: %d MB / %d MB\n"
                "Check self RAM usage: %d MB\n",
                freeRamMb, totalRamMb,
                ru.ru_maxrss / 1024);
        if (freeRamMb < 200) {
            // Hard die if we are likely to run out of RAM, because
            // that will lock the system (making it hard to ssh in,
            // etc).
            fprintf(stderr, "--------------------\n"
                    "OUT OF RAM, EXITING.\n"
                    "--------------------\n");
            exit(1);
        }
    }
#endif

    // Second: deal with any remove-later (sustains).
    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        StatementRef stmtRef = removeLater[i].stmt;
        if (!statementRefIsNull(stmtRef)) {
            if (removeLater[i].canRemoveAtTick >= currentTick) {
                // Remove immediately on sysmon thread so there's no
                // pileup.
                Statement* stmt;
                if ((stmt = statementAcquire(db, stmtRef))) {
                    statementRemoveParentAndMaybeRemoveSelf(db, stmt);
                    statementRelease(db, stmt);
                }

                removeLater[i].canRemoveAtTick = 0;
                removeLater[i].stmt = STATEMENT_REF_NULL;
            }
        }
    }

    // Third: manage the pool of worker threads.
    // How many workers are 'available'?
    int availableWorkersCount = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0) { continue; }

        // Check work item start timestamp. Been working for less than
        // 10 ms? We'll count it as available.
        int64_t now = timestamp_get(threads[i].clockid);
        if (threads[i].currentItemStartTimestamp == 0 ||
            now - threads[i].currentItemStartTimestamp < 10000000) {

            availableWorkersCount++;
        }
    }
    if (availableWorkersCount < 2) {
        // new worker spawns should be safe, legal, and rare.
        fprintf(stderr, "workerSpawn (count = %d)\n", availableWorkersCount);
        workerSpawn();
    }

    // Fourth: update the clock time statement in the database.
    // sysmon.c claims the clock time is <TIME>
    int64_t timeNs = timestamp_get(CLOCK_REALTIME);
    Clause* clockTimeClause = malloc(SIZEOF_CLAUSE(7));
    clockTimeClause->nTerms = 7;
    clockTimeClause->terms[0] = strdup("sysmon.c");
    clockTimeClause->terms[1] = strdup("claims");
    clockTimeClause->terms[2] = strdup("the");
    clockTimeClause->terms[3] = strdup("clock");
    clockTimeClause->terms[4] = strdup("time");
    clockTimeClause->terms[5] = strdup("is");
    asprintf(&clockTimeClause->terms[6], "%f",
             (double)timeNs / 1000000000.0);

    globalWorkQueuePush((WorkQueueItem) {
            .op = HOLD,
            .thread = -1,
            .hold = {
                .key = strdup("clock-time"),
                .version = currentTick,
                .sustainMs = 0,
                .clause = clockTimeClause,
                .sourceFileName = strdup("sysmon.c"),
                .sourceLineNumber = __LINE__
            }
        });
}

void *sysmonMain(void *ptr) {
    struct timespec tickTime;
    tickTime.tv_sec = 0;
    tickTime.tv_nsec = SYSMON_TICK_MS * 1000 * 1000;
    for (;;) {
        nanosleep(&tickTime, NULL);

        tick++;
        sysmon();
    }
    return NULL;
}
// This gets called from other threads.
void sysmonRemoveLater(StatementRef stmtRef, int laterMs) {
    int laterTicks = laterMs / SYSMON_TICK_MS;

    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        StatementRef oldStmtRef = removeLater[i].stmt;
        if (statementRefIsNull(oldStmtRef) &&
            atomic_compare_exchange_weak(&removeLater[i].stmt,
                                         &oldStmtRef,
                                         stmtRef)) {

            removeLater[i].canRemoveAtTick = tick + laterTicks;
            break;
        }
    }
    if (i == REMOVE_LATER_MAX) {
        fprintf(stderr, "sysmon: Ran out of remove-later slots!");
        exit(1);
    }
}
