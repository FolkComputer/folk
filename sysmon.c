// Inspired by Golang's sysmon. Gotta catch 'em all...

#include <stdio.h>

#include "common.h"

extern ThreadControlBlock threads[];

void sysmon() {
    int activeWorkersCount = 0;
    printf("-----\n");
    for (int i = 0; i < THREADS_MAX; i++) {
        // We can be a little sketchy with the counting.
        pid_t tid = threads[i].tid;
        if (tid == 0) { continue; }

        // Check state of tid.
        char path[100]; snprintf(path, 100, "/proc/%d/stat", tid);
        FILE *fp = fopen(path, "r");
        int _pid; char _name[100]; char state;
        // TODO: doesn't deal with name with space in it.
        fscanf(fp, "%d %s %c ", &_pid, &_name, &state);

        printf("%d: %c\n", tid, state);

        // How long has it been running in the current burst?

        // Is it blocked on the OS (sleeping state)?
        
    }
    if (activeWorkersCount) {
        // Spawn a new worker.
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
