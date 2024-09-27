// Inspired by Golang's sysmon. Gotta catch 'em all...

#include <unistd.h>
#include <stdio.h>
#include <time.h>

#include "common.h"

extern ThreadControlBlock threads[];
extern Db* db;

void workerSpawn();

#define SYSMON_TICK_MS 2

typedef struct RemoveLater {
    StatementRef stmt;
    int64_t canRemoveAtTick;
} RemoveLater;

#define REMOVE_LATER_MAX 30
RemoveLater removeLater[REMOVE_LATER_MAX];
pthread_mutex_t removeLaterMutex;

int64_t _Atomic tick;

void sysmonInit() {
    pthread_mutex_init(&removeLaterMutex, NULL);
}

void sysmon() {
    // This is the system monitoring routine that runs on every tick
    // (every few milliseconds).
    int64_t currentTick = tick;

    // First: deal with any remove-later (sustains).
    pthread_mutex_lock(&removeLaterMutex);
    int i;
    for (i = 0; i < REMOVE_LATER_MAX; i++) {
        if (!statementRefIsNull(removeLater[i].stmt)) {
            Statement* stmt;
            if (removeLater[i].canRemoveAtTick >= currentTick &&
                (stmt = statementAcquire(db, removeLater[i].stmt))) {

                statementRemoveParentAndMaybeRemoveSelf(db, stmt);
                statementRelease(db, stmt);
            }
            removeLater[i].stmt = STATEMENT_REF_NULL;
            removeLater[i].canRemoveAtTick = 0;
        }
    }
    pthread_mutex_unlock(&removeLaterMutex);

    // Second: manage the pool of worker threads.
    int availableWorkersCount = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0) { continue; }

        // Check state of tid.
        char path[100]; snprintf(path, 100, "/proc/%d/stat", tid);
        FILE *fp = fopen(path, "r");
        if (fp == NULL) { continue; }
        int _pid; char _name[100]; char state;
        // TODO: doesn't deal with name with space in it.
        fscanf(fp, "%d %s %c ", &_pid, _name, &state);
        fclose(fp);

        if (state == 'R' || threads[i].isAwaitingPush) {
            availableWorkersCount++;
        }

        // How long has it been running in the current burst?
        // Is it blocked on the OS (sleeping state)?
    }
    if (availableWorkersCount < 2) {
        fprintf(stderr, "workerSpawn\n");
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
