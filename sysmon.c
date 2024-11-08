// Inspired by Golang's sysmon. Gotta catch 'em all...

#include <unistd.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <inttypes.h>

#include "common.h"

// TODO: declare these in folk.h or something.
extern ThreadControlBlock threads[];
extern Db* db;
extern void trace(const char* format, ...);

extern WorkQueue* globalWorkQueue;
extern pthread_mutex_t globalWorkQueueMutex;

void workerSpawn();

// HACK: ncpus - 1
#define THREADS_ACTIVE_TARGET 3

#define SYSMON_TICK_MS 2

typedef struct RemoveLater {
    StatementRef stmt;
    int64_t canRemoveAtTick;
} RemoveLater;

#define REMOVE_LATER_MAX 30
RemoveLater removeLater[REMOVE_LATER_MAX];
pthread_mutex_t removeLaterMutex;

int64_t _Atomic tick;

int64_t timestampAtBoot;

void sysmonInit() {
    pthread_mutex_init(&removeLaterMutex, NULL);
    timestampAtBoot = timestamp_get(CLOCK_MONOTONIC);
}

void sysmon() {
    trace("%" PRId64 "us: Sysmon Tick",
          timestamp_get(CLOCK_MONOTONIC) - timestampAtBoot);

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
        fprintf(stderr, "Check avail RAM: %d MB / %d MB\n",
                freeRamMb,
                totalRamMb);
        if (freeRamMb < 100) {
            // Hard die if we are likely to run out of RAM, because
            // that will lock the system (making it hard to ssh in,
            // etc).
            exit(1);
        }
    }
#endif

    // Second: deal with any remove-later (sustains).
    pthread_mutex_lock(&removeLaterMutex);
    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        if (!statementRefIsNull(removeLater[i].stmt)) {
            if (removeLater[i].canRemoveAtTick >= currentTick) {
                pthread_mutex_lock(&globalWorkQueueMutex);
                workQueuePush(globalWorkQueue, (WorkQueueItem) {
                        .op = REMOVE_PARENT,
                        .thread = -1,
                        .removeParent = { .stmt = removeLater[i].stmt }
                    });
                pthread_mutex_unlock(&globalWorkQueueMutex);

                removeLater[i].stmt = STATEMENT_REF_NULL;
                removeLater[i].canRemoveAtTick = 0;
            }
        }
    }
    pthread_mutex_unlock(&removeLaterMutex);

    // Third: manage the pool of worker threads.
    // How many workers are 'available'?
    int availableWorkersCount = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0) { continue; }

        // Check state of tid.
        /* char path[100]; snprintf(path, 100, "/proc/%d/stat", tid); */
        /* FILE *fp = fopen(path, "r"); */
        /* if (fp == NULL) { continue; } */
        /* int _pid; char _name[100]; char state; */
        /* // TODO: doesn't deal with name with space in it. */
        /* fscanf(fp, "%d %s %c ", &_pid, _name, &state); */
        /* fclose(fp); */

        // We want to know when a thread will be likely to be ready to
        // take on new work.

        // so, we want to estimate how long its current work item will
        // take.

        // We want to count the number of threads that are ready to
        // take on new work.

        // what if the thread gets/got preempted? it'll totally screw
        // over the elapsed time estimate.

        // Check work item start timestamp. Been working for less than
        // 10 ms? We'll count it as available.
        int64_t now = timestamp_get(threads[i].clockid);
        if (threads[i].currentItemStartTimestamp == 0 ||
            now - threads[i].currentItemStartTimestamp < 10000000) {

            availableWorkersCount++;
        }
        // FIXME: what if we get in a loop where we keep spawning threads?

        // Should we mark any thread in a C call mid-match (or simply
        // sleeping on the OS?) as being no longer pinned?  Should we
        // pin worker threads to the CPU?

        // We want ncpus worker threads.

        // What if a worker thread is genuinely busy with compute?

        // How long has it been running in the current burst?
        // Is it blocked on the OS (sleeping state)?
    }
    if (availableWorkersCount < 2) {
        // new worker spawns should be safe, legal, and rare.
        fprintf(stderr, "workerSpawn (count = %d)\n", availableWorkersCount);
        workerSpawn();
    }
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
    // TODO: Round laterMs up to a number of ticks.
    // Then put it into the tick slot.
    int laterTicks = laterMs / SYSMON_TICK_MS;

    pthread_mutex_lock(&removeLaterMutex);
    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        if (statementRefIsNull(removeLater[i].stmt)) {
            removeLater[i].stmt = stmtRef;
            removeLater[i].canRemoveAtTick = tick + laterTicks;
            break;
        }
    }
    if (i == REMOVE_LATER_MAX) {
        fprintf(stderr, "sysmon: Ran out of remove-later slots!");
        exit(1);
    }
    pthread_mutex_unlock(&removeLaterMutex);
}
