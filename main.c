#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

#include <pqueue.h>

#include "workqueue.h"

WorkQueue* workQueue;

void* worker_main(void* arg) {
    int x;
    printf("Worker %p\n", &x);
}

int main() {
    // Do all setup.

    // Set up database.

    // Set up workqueue.
    workQueue = workQueueNew();

    // Spawn NCPUS workers.
    for (int i = 0; i < 4; i++) {
        pthread_t th;
        pthread_create(&th, NULL, worker_main, NULL);
    }

    usleep(1000000);
}
