#ifndef WORKQUEUE_H
#define WORKQUEUE_H

#include "trie.h"

typedef struct WorkQueue WorkQueue;
typedef enum WorkQueueOp { NONE, ASSERT, RETRACT } WorkQueueOp;

WorkQueue* workQueueNew();
void workQueueAssert(WorkQueue* q, Clause* clause);
void workQueueRetract(WorkQueue* q, Clause* pattern);

#endif
