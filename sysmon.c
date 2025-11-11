// Inspired by Golang's sysmon. Gotta catch 'em all...

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
#include "epoch.h"

// TODO: declare these in folk.h or something.
extern ThreadControlBlock threads[];
extern Db* db;
extern void trace(const char* format, ...);
extern void HoldStatementGlobally(const char *key, double version,
                                  Clause *clause, long keepMs, const char *destructorCode,
                                  const char *sourceFileName, int sourceLineNumber);
extern void workerReactivateOrSpawn(int64_t msSinceBoot);
extern void dbGarbageCollectAtomicallys(Db* db, int64_t now);

// How many ms are in each tick? You probably want this to be less
// than half of 16ms (1 frame).
#define SYSMON_TICK_MS 3

typedef struct RemoveLater {
    StatementRef _Atomic stmt;
    int64_t _Atomic canRemoveAtTick;
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
    int64_t currentMs = currentTick * SYSMON_TICK_MS;

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
                "Check self RAM usage: %ld MB\n",
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

    // Second: deal with any remove-later statements that we should
    // remove.
    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        StatementRef stmtRef = removeLater[i].stmt;
        if (!statementRefIsNull(stmtRef)) {
            int64_t canRemoveAt = removeLater[i].canRemoveAtTick;
            // Skip if canRemoveAtTick hasn't been written yet (still 0)
            if (canRemoveAt > 0 && currentTick >= canRemoveAt) {
                // Remove immediately on sysmon thread so there's no
                // pileup.
                Statement* stmt;
                if ((stmt = statementAcquire(db, stmtRef))) {
                    statementDecrParentCountAndMaybeRemoveSelf(db, stmt);
                    statementRelease(db, stmt);
                }

                removeLater[i].canRemoveAtTick = 0;
                removeLater[i].stmt = STATEMENT_REF_NULL;
            }
        }
    }

    // Third: collect garbage.
    epochGlobalCollect();

    // Fourth: reap Atomically versions / attached statements that
    // haven't had a new convergence in 'a long time'.
    if (currentTick % 20 == 0) { // every 60ms or so.
        int64_t nowNs = timestamp_get(CLOCK_MONOTONIC);
        dbGarbageCollectAtomicallys(db, nowNs);
    }

    ///////////////////////////////////
    if (currentMs < 1000) { return; }
    // Don't do the management tasks after this if the system isn't
    // fully online yet.
    ///////////////////////////////////

    // Fifth: manage the pool of worker threads.
    // How many workers are _not_ blocked on I/O?
#ifdef __linux__
    int notBlockedWorkersCount = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0 || threads[i].isDeactivated) { continue; }

        char path[100]; snprintf(path, 100, "/proc/%d/stat", tid);
        FILE *fp = fopen(path, "r");
        if (fp == NULL) { continue; }
        int _pid; char _name[100]; char state;
        // TODO: doesn't deal with name with space in it.
        if (fscanf(fp, "%d %s %c ", &_pid, _name, &state) != 3) {
            fprintf(stderr, "sysmon: /proc/%d/stat scan failed\n", tid);
        }
        fclose(fp);

        // If it's running, then we'll count it as non-blocked.
        if (state == 'R') {
            notBlockedWorkersCount++;
            threads[i].wasObservedAsBlocked = false;
        } else {
            // Mark that the thread was blocked on I/O so that the
            // thread can deactivate when done with its current work
            // item (so we don't get overcrowding of threads for the #
            // of CPUs).
            threads[i].wasObservedAsBlocked = true;
        }
    }
    // TODO: Use NCPUS for this.
    if (notBlockedWorkersCount < 3) {
        // Too many threads are blocked on I/O. Let's pull in another
        // one to occupy a CPU and do Folk work.
        workerReactivateOrSpawn(currentMs);
    }
#endif

    // Sixth: update the time statements in the database.
    int64_t timeNs = timestamp_get(CLOCK_REALTIME);

    // sysmon.c claims the internal time is <TIME> (used internally)
    Clause* internalTimeClause = malloc(SIZEOF_CLAUSE(7));
    internalTimeClause->nTerms = 7;
    internalTimeClause->terms[0] = strdup("sysmon.c");
    internalTimeClause->terms[1] = strdup("claims");
    internalTimeClause->terms[2] = strdup("the");
    internalTimeClause->terms[3] = strdup("internal");
    internalTimeClause->terms[4] = strdup("time");
    internalTimeClause->terms[5] = strdup("is");
    internalTimeClause->terms[6] = malloc(100);
    snprintf(internalTimeClause->terms[6], 100, "%f",
             (double)timeNs / 1000000000.0);

    HoldStatementGlobally("internal-time", currentTick,
                          internalTimeClause, 0, NULL,
                          "sysmon.c", __LINE__);

    // sysmon.c claims the clock time is <TIME>
    if (currentTick % 3 == 0) {
        Clause* clockTimeClause = malloc(SIZEOF_CLAUSE(7));
        clockTimeClause->nTerms = 7;
        clockTimeClause->terms[0] = strdup("sysmon.c");
        clockTimeClause->terms[1] = strdup("claims");
        clockTimeClause->terms[2] = strdup("the");
        clockTimeClause->terms[3] = strdup("clock");
        clockTimeClause->terms[4] = strdup("time");
        clockTimeClause->terms[5] = strdup("is");
        clockTimeClause->terms[6] = malloc(100);
        snprintf(clockTimeClause->terms[6], 100, "%f",
                 (double)timeNs / 1000000000.0);

        HoldStatementGlobally("clock-time", currentTick,
                              clockTimeClause, 0, NULL,
                              "sysmon.c", __LINE__);
    }
}

void *sysmonMain(void *ptr) {
#ifdef TRACY_ENABLE
    TracyCSetThreadName("sysmon");
#endif

    epochThreadInit();

    tick = 0;

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
void sysmonScheduleRemoveAfter(StatementRef stmtRef, int afterMs) {
    int afterTicks = afterMs / SYSMON_TICK_MS;

    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        StatementRef oldStmtRef = removeLater[i].stmt;
        if (statementRefIsNull(oldStmtRef) &&
            atomic_compare_exchange_weak(&removeLater[i].stmt,
                                         &oldStmtRef, stmtRef)) {

            removeLater[i].canRemoveAtTick = tick + afterTicks;
            break;
        }
    }
    if (i == REMOVE_LATER_MAX) {
        fprintf(stderr, "sysmon: Ran out of remove-later slots!");
        for (int i = 0; i < REMOVE_LATER_MAX; i++) {
            fprintf(stderr, "  %d: (%.200s)\n", i,
                    clauseToString(statementClause(statementAcquire(db, removeLater[i].stmt))));
        }
        exit(1);
    }
}
