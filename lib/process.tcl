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
    set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
    set processCode [list apply {{__name __body} {
        set ::thisProcess $__name

        Assert <lib/process.tcl> wishes $::thisProcess shares all wishes
        Assert <lib/process.tcl> wishes $::thisProcess shares all claims

        ::peer "localhost" true

        Assert <lib/process.tcl> claims $::thisProcess has pid [pid]
        Assert when $::thisProcess has pid /something/ [list {} $__body]
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

    # Wrap these in a new scope so they don't capture a bunch of
    # random stuff from this outer scope.
    apply {{this name} {
        # This When and On unmatch will be part of the caller match,
        # because they bind to the current global ::matchId (so this
        # When should unmatch if the caller unmatches, leading to the
        # subprocess getting killed).
        When $name has pid /pid/ {
            On unmatch {
                exec kill -9 $pid
            }
        }
        On unmatch {
            # Remember to suppress/kill the process if it shows up
            # later after we're gone.
            dict set ::peersBlacklist $name true
            after 5000 [list dict unset ::peersBlacklist $name]
        }
    }} $this $name
}
