source "lib/c.tcl"

set cc [c create]
$cc include <unistd.h>
$cc code {
    // TODO: Make C work queue.
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
