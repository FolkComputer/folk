// Inspired by Golang's sysmon. Gotta catch 'em all...

#include <unistd.h>
#include <stdio.h>

#include "common.h"

extern ThreadControlBlock threads[];

void workerSpawn();
void sysmon() {
    int availableWorkersCount = 0;
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0) { continue; }

        // Check state of tid.
        char path[100]; snprintf(path, 100, "/proc/%d/stat", tid);
        FILE *fp = fopen(path, "r");
        int _pid; char _name[100]; char state;
        // TODO: doesn't deal with name with space in it.
        fscanf(fp, "%d %s %c ", &_pid, _name, &state);

        if (state == 'R' || threads[i].isAwaitingPush) {
            availableWorkersCount++;
        }

        // How long has it been running in the current burst?
        // Is it blocked on the OS (sleeping state)?
    }
    if (availableWorkersCount < 2) {
        workerSpawn();
    }
}

void *sysmonMain(void *ptr) {
    for (;;) {
        /* usleep(1000); // sleep for 1ms. */
        usleep(1000000);
        sysmon();
    }
    return NULL;
}
