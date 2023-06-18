namespace eval ::Zygote {
    set cc [c create]
    $cc include <unistd.h>
    $cc proc ::Zygote::fork {} int { return fork(); }
    # FIXME: waitpid
    # FIXME: some kind of shared-memory log queue
    $cc compile

    # The zygote is a process that's forked off during Folk
    # startup. It can fork itself to create subprocesses on demand.

    # Fork Folk to create the zygote process (= set the current state
    # of Folk as the startup state for all subprocesses that will be
    # spawned later)
    proc init {} {
        variable reader
        variable writer
        lassign [chan pipe] reader writer
        set pid [fork]
        if {$pid == 0} {
            # We're in the child (the zygote). We will block waiting
            # for commands from the parent (the original/main thread).
            close $writer
            fconfigure $reader -buffering line
            zygote

        } else {
            # We're still in the parent. The child (the zygote) is $pid.
            close $reader
            # We will send the zygote a message every time we want it to
            # fork.
            fconfigure $writer -buffering line
        }
    }
    # Zygote's main loop.
    proc zygote {} {
        variable reader
        set script ""
        while {[gets $reader line] != -1} {
            append script $line\n
            if {[info complete $script]} {
                set pid [fork]
                if {$pid == 0} {
                    eval $script
                    exit 0
                }
                set script ""
            }
        }
        exit 0
    }

    proc spawn {code} {
        variable writer
        puts $writer $code
    }
}

proc On-process {name body} {
    namespace eval ::Processes::$name {}
    set ::Processes::${name}::name $name
    set ::Processes::${name}::body $body
    set ::Processes::${name}::this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
    namespace eval ::Processes::$name {
        set processCode [list apply {{__name __body} {
            set ::thisProcess $__name

            Assert <lib/process.tcl> wishes $::thisProcess shares all statements

            ::peer "localhost"

            Assert <lib/process.tcl> claims $::thisProcess has pid [pid]
            Assert <lib/process.tcl> claims $::thisProcess has program [list {_} $__body]
            Step
            vwait forever
        }} $name $body]

        Zygote::spawn [list apply {{processCode} {
            # A supervisor that wraps the subprocess.
            set pid [Zygote::fork]
            if {$pid == 0} {
                eval $processCode
            } else {
                # TODO: Supervise the subprocess.
                # waitpid $pid
                # how to report outcomes to Folk?
                # does it have an inbox? do we assert into Folk and let it retract?
            }
        }} $processCode]

        proc handleUnmatch {} {
            variable pid
            variable name
            variable stdout_reader
            close $stdout_reader
            exec kill -9 $pid 
            while {1} {
              try {
                exec kill -0 $pid
              } on error err {
                break
              }
            }
            Retract /someone/ is running process $name
            namespace delete ::Processes::$name
        }
        uplevel 2 [list On unmatch ::Processes::${name}::handleUnmatch]
    }
}
