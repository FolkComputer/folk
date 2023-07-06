source "lib/c.tcl"
set cc [c create]
$cc include <unistd.h>
$cc proc ::fork {} int {
    return fork();
}
$cc compile

namespace eval Zygote {
    proc init {} {
        variable writer
        lassign [chan pipe] reader writer
        set pid [fork]
        if {$pid == 0} {
            # We're in the child (the zygote). We will block waiting
            # for commands from the parent (the original/main thread).
            close $writer

            fconfigure $reader -buffering line
            # Zygote's main loop:
            set script ""
            while {[gets $reader line] != -1} {
                append script $line\n
                if {[info complete $script]} {
                    # FIXME: This fork breaks it.
                    set pid [fork]
                    if {$pid == 0} {
                        eval $script
                        exit 0
                    }
                    set script ""
                }
            }
            exit 0

        } else {
            # We're still in the parent. The child (the zygote) is $pid.
            close $reader
            # We will send the zygote a message every time we want it to
            # fork.
            fconfigure $writer -buffering line
        }
    }
    proc spawn {code} {
        variable writer
        puts $writer $code
    }
}

Zygote::init

Zygote::spawn {
    puts "hello from [pid]"
}
Zygote::spawn {
    puts "wow from [pid]"
}

after 3000 { puts done; set ::done true }
vwait ::done
