#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

#include <pqueue.h>

#include "workqueue.h"

WorkQueue* workQueue;
pthread_mutex_t workQueueMutex;

void workerRun(WorkQueueItem item) {
    
}
void* workerMain(void* arg) {
    int id = (int) arg;
    for (;;) {
        pthread_mutex_lock(&workQueueMutex);
        WorkQueueItem item = workQueuePop(workQueue);
        pthread_mutex_unlock(&workQueueMutex);

        // TODO: if item is none, then sleep or wait on condition
        // variable.
        printf("Worker %d: item %d\n", id, item.op);
        workerRun(item);
    }
}

int main() {
    // Do all setup.

    // Set up database.

    // Set up workqueue.
    workQueue = workQueueNew();
    pthread_mutex_init(&workQueueMutex, NULL);

    // Queue up some items (JUST FOR TESTING)
    workQueuePush(workQueue, (WorkQueueItem) { .op = ASSERT });
    workQueuePush(workQueue, (WorkQueueItem) { .op = ASSERT });
    workQueuePush(workQueue, (WorkQueueItem) { .op = ASSERT });

    // Spawn NCPUS workers.
    for (int i = 0; i < 4; i++) {
        pthread_t th;
        pthread_create(&th, NULL, workerMain, i);
    }

    usleep(1000000);
}
