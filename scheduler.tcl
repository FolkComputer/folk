source "lib/c.tcl"

set cc [c create]

$cc cflags -I./vendor/shm_malloc vendor/shm_malloc/libshm.a
$cc include "shm_malloc.h"

$cc cflags -I./vendor/libpqueue/src \
    -Dmalloc=shm_malloc -Dfree=shm_free \
    vendor/libpqueue/src/pqueue.c \
    -Umalloc -Ufree
$cc include "pqueue.h"

$cc include <unistd.h>
$cc code {
    typedef enum QueueOp { NONE, ASSERT, RETRACT } QueueOp;
    typedef struct QueueEntry {
        QueueOp op;
        int seq;

        union {
            struct { Jim_Obj* clause } assert;
            struct { Jim_Obj* pattern } retract;
        };
    } QueueEntry;

    // TODO: Lock the workQueue.
    // TODO: Allocate in shared memory.
    pqueue_t* workQueue;
    int seq;

    int queueEntryCompare(pqueue_pri_t next, pqueue_pri_t curr) {
        return next < curr;
    }
    pqueue_pri_t queueEntryGetPriority(void* a) {
        QueueEntry* entry = a;
        switch (entry->op) {
            case NONE: return 0;
            case ASSERT:
            case RETRACT: return 80000 - entry->seq;
        }
        return 0;
    }
    void queueEntrySetPriority(void* a, pqueue_pri_t pri) {}
    size_t queueEntryGetPosition(void* a) { return 0; }
    void queueEntrySetPosition(void* a, size_t pos) {}
}
$cc proc init {} void {
    if (shm_init(NULL, NULL) != 0) {
        fprintf(stderr, "scheduler: init: shm_init failed\n");
        abort();
    }

    workQueue = pqueue_init(16384,
                            queueEntryCompare,
                            queueEntryGetPriority,
                            queueEntrySetPriority,
                            queueEntryGetPosition,
                            queueEntrySetPosition);
}
$cc proc process {} void {
    int pid = getpid();
    // Worker thread.
    // Repeatedly draw from work queue.
    for (;;) {
        printf("Process %d\n", pid);
        sleep(1);
    }
}

$cc proc forque {} int {
    if (fork() == 0) {
        process();

        fprintf(stderr, "Error: process() terminated.\n");
        abort(); // should never be reached
    }
}

$cc compile

# TODO: fork NUM_CPUS times
init
forque
forque
forque

# Set up work for the subprocesses.
puts "TODO: Set up work"
exec sleep 10

proc Assert {args} { error "Assert: Unimplemented" }
proc Folk {code} {
    # Assert to run $code
}

# TODO: have an interrupt watchdog?

Folk {
    Claim Mac is an OS
    Claim Linux is an OS
    Claim Windows is an OS

    When /x/ is an OS {
        sleep 3
        Claim $x really is an OS
    }

    When Mac really is an OS \&
         Linux really is an OS \&
         Windows really is an OS {
        puts "Passed"
        exit 0
    }
}
