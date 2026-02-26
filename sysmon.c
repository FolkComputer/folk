// Inspired by Golang's sysmon. Gotta catch 'em all...

#include <unistd.h>
#include <stdio.h>
#include <fcntl.h>

#include <time.h>
#include <sys/time.h>
#include <inttypes.h>
#include <string.h>
#include <stdatomic.h>
#include <assert.h>

#ifdef __linux__
#include <sys/sysinfo.h>
#include <sys/resource.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <mach/mach.h>
#endif

#include "common.h"
#include "epoch.h"

extern void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);

// TODO: declare these in folk.h or something.
extern ThreadControlBlock threads[];
extern Db* db;
extern void trace(const char* format, ...);
extern void HoldStatementGlobally(const char *key, double version,
                                  Clause *clause, long keepMs, const char *destructorCode,
                                  const char *sourceFileName, int sourceLineNumber);
extern void workerReactivateOrSpawn(int64_t msSinceBoot, int targetNotBlockedWorkersCount);
extern void dbGarbageCollectAtomicallys(Db* db, int64_t now);

// How many ms are in each tick? You probably want this to be less
// than half of 16ms (1 frame).
#define SYSMON_TICK_MS 3

char thisNode[256];

typedef struct RemoveLater {
    StatementRef _Atomic stmt;
    int64_t _Atomic canRemoveAtTick;
} RemoveLater;

#define REMOVE_LATER_MAX 1000
RemoveLater removeLater[REMOVE_LATER_MAX];

int64_t _Atomic tick;

int64_t timestampAtBoot;
int targetNotBlockedWorkersCount;

void sysmonInit(int targetCount) {
    timestampAtBoot = timestamp_get(CLOCK_MONOTONIC);
    targetNotBlockedWorkersCount = targetCount;
}

static void checkRam();
void sysmon() {
    /* trace("%" PRId64 "ns: Sysmon Tick", */
    /*       timestamp_get(CLOCK_MONOTONIC) - timestampAtBoot); */

    // This is the system monitoring routine that runs on every tick
    // (every few milliseconds).
    int64_t currentTick = tick;
    int64_t currentMs = currentTick * SYSMON_TICK_MS;

    // First: check that we have a reasonable amount of free RAM.
    // TODO: move this check to userspace.
    if (currentTick % 1000 == 0) {
        // assuming that ticks happen every 2ms, this should happen
        // every 2s.
        checkRam();
    }

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

    if (notBlockedWorkersCount < targetNotBlockedWorkersCount) {
        workerReactivateOrSpawn(currentMs, targetNotBlockedWorkersCount);
    }
#endif

    // Sixth: update the time statements in the database.
    int64_t timeNs = timestamp_get(CLOCK_REALTIME);

    Clause* internalTimeClause = clauseFormat(
        "sysmon.c claims the internal time is %f",
        (double)timeNs / 1000000000.0);
    HoldStatementGlobally("internal-time", currentTick,
                          internalTimeClause, 0, NULL,
                          "sysmon.c", __LINE__);

    if (currentTick % 3 == 0) {
        Clause* clockTimeClause = clauseFormat(
            "sysmon.c claims the clock time is %f",
            (double)timeNs / 1000000000.0);
        HoldStatementGlobally("clock-time", currentTick,
                              clockTimeClause, 0, NULL,
                              "sysmon.c", __LINE__);
    }
}

static void checkRam() {
#ifdef __linux__
    // Read MemAvailable from /proc/meminfo (includes reclaimable buffers/cache)
    int freeRamMb = 0;

    static FILE* meminfo = NULL;
    if (meminfo == NULL) {
        meminfo = fopen("/proc/meminfo", "r");
    }
    assert(meminfo != NULL);
    rewind(meminfo);

    char line[256];
    while (fgets(line, sizeof(line), meminfo)) {
        long memAvailableKb;
        if (sscanf(line, "MemAvailable: %ld kB", &memAvailableKb) == 1) {
            freeRamMb = memAvailableKb / 1024;
            break;
        }
    }
    // Fallback to old method if /proc/meminfo reading failed
    if (freeRamMb == 0) {
        freeRamMb = get_avphys_pages() * sysconf(_SC_PAGESIZE) / 1000000;
    }

    int totalRamMb = get_phys_pages() * sysconf(_SC_PAGESIZE) / 1000000;
    // Check directly folk's own use of RAM, so we can
    // detect leaks (I think system RAM is good for killing but
    // process RAM use is better for leak diagnosis).
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    int selfRamMb = ru.ru_maxrss / 1024;
#endif
#ifdef __APPLE__
    // Get total physical memory
    int64_t totalRamBytes = 0;
    size_t len = sizeof(totalRamBytes);
    if (sysctlbyname("hw.memsize", &totalRamBytes, &len, NULL, 0) != 0) {
        totalRamBytes = 0;
    }
    int totalRamMb = totalRamBytes / (1024 * 1024);

    // Get VM statistics for free/available memory
    vm_size_t page_size;
    mach_port_t mach_port = mach_host_self();
    mach_msg_type_number_t count = sizeof(vm_statistics64_data_t) / sizeof(integer_t);
    vm_statistics64_data_t vm_stats;

    int freeRamMb = 0;
    if (host_page_size(mach_port, &page_size) == KERN_SUCCESS &&
        host_statistics64(mach_port, HOST_VM_INFO64, (host_info64_t)&vm_stats, &count) == KERN_SUCCESS) {
        // Calculate available memory (free + inactive + purgeable)
        int64_t free_pages = vm_stats.free_count;
        int64_t inactive_pages = vm_stats.inactive_count;
        int64_t purgeable_pages = vm_stats.purgeable_count;
        int64_t available_bytes = (free_pages + inactive_pages + purgeable_pages) * page_size;
        freeRamMb = available_bytes / (1024 * 1024);
    }

    // Check process's own RAM usage
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    // Note: On macOS, ru_maxrss is in bytes, not kilobytes like Linux
    int selfRamMb = ru.ru_maxrss / (1024 * 1024);
#endif

    HoldStatementGlobally("selfRam", tick,
                          clauseFormat("sysmon.c claims %s has self RAM usage %d MB",
                                       thisNode, selfRamMb),
                          0, NULL, "sysmon.c", __LINE__);
    HoldStatementGlobally("totalRam", tick,
                          clauseFormat("sysmon.c claims %s has available RAM %d MB of %d MB",
                                       thisNode, freeRamMb, totalRamMb),
                          0, NULL, "sysmon.c", __LINE__);

    if (freeRamMb < 200) {
        // Hard die if we are likely to run out of RAM
        fprintf(stderr, "--------------------\n"
                "OUT OF RAM, EXITING.\n"
                "--------------------\n");
        exit(1);
    }
}

void *sysmonMain(void *ptr) {
#ifdef TRACY_ENABLE
    TracyCSetThreadName("sysmon");
#endif

    epochThreadInit();

    {
        char path[256];
        snprintf(path, sizeof(path), "/tmp/%d.sysmon.c.stdout", getpid());
        int outfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        snprintf(path, sizeof(path), "/tmp/%d.sysmon.c.stderr", getpid());
        int errfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        installLocalStdoutAndStderr(outfd, errfd);
    }

    tick = 0;
    gethostname(thisNode, sizeof(thisNode));

    struct timespec tickTime;
    tickTime.tv_sec = 0;
    tickTime.tv_nsec = SYSMON_TICK_MS * 1000 * 1000;
    for (;;) {
        nanosleep(&tickTime, NULL);

        tick++;

#ifdef TRACY_ENABLE
        TracyCZoneN(zone, "sysmon", 1);
#endif
        sysmon();
#ifdef TRACY_ENABLE
        TracyCZoneEnd(zone);
#endif
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
