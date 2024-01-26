#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

#include <pqueue.h>

#include "workqueue.h"

WorkQueue* workQueue;
pthread_mutex_t workQueueMutex;

void* workerMain(void* arg) {
    int id = (int) arg;
    for (;;) {
        pthread_mutex_lock(&workQueueMutex);
        WorkQueueItem item = workQueuePop(workQueue);
        pthread_mutex_unlock(&workQueueMutex);

        printf("Worker %d: item %d\n", id, item.op);
    }
}

int main() {
    // Do all setup.

    // Set up database.

    // Set up workqueue.
    workQueue = workQueueNew();
    pthread_mutex_init(&workQueueMutex, NULL);

    // Spawn NCPUS workers.
    for (int i = 0; i < 4; i++) {
        pthread_t th;
        pthread_create(&th, NULL, workerMain, i);
    }

    usleep(1000000);
}
