namespace eval ::Zygote {
    set cc [c create]
    $cc include <unistd.h>
    $cc include <sys/wait.h>
    $cc proc ::Zygote::fork {} int { return fork(); }
    $cc proc ::Zygote::wait {} int {
        return wait(NULL);
    }
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

proc Start-process {name body} {
    if {[namespace exists ::Peers::$name]} {
        error "Process $name already exists"
        return
    }

    set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
    set processCode [list apply {{__parentProcess __name __body} {
        set ::thisProcess $__name

        ::peer $__parentProcess true

        Assert <lib/process.tcl> wishes $::thisProcess shares statements like \
            [list /someone/ claims $::thisProcess has pid /something/]
        Assert <lib/process.tcl> wishes $::thisProcess receives statements like \
            [list /someone/ wishes program code /code/ runs on $::thisProcess]
        Assert <lib/process.tcl> wishes $::thisProcess shares statements like \
            [list /someone/ wishes $::thisProcess receives statements like /pattern/]

        Assert <lib/process.tcl> claims $::thisProcess has pid [pid]
        # Run __body one Step before running any other program code.
        Assert when $::thisProcess has pid /something/ [list {__body} {
            When /someone/ wishes program code /__code/ runs on $::thisProcess {
                eval $__code
            }
            eval $__body
        }] with environment [list $__body]

        while true { Step }
    }} $::thisProcess $name $body]

    ::peer $name false

    Zygote::spawn [list apply {{processName processCode} {
        # A supervisor that wraps the subprocess.
        set pid [Zygote::fork]
        if {$pid == 0} {
            eval $processCode
        } else {
            set deadPid [Zygote::wait]
            if {$deadPid == $pid} {
                puts stderr "process: Subprocess '$processName' ($pid) died!"
            } else {
                error "process: Unknown pid $deadPid died."
            }
            # TODO: how to report outcomes to Folk?
            # does it have an inbox? do we assert into Folk and let it retract?
        }
    }} $name $processCode]

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
	    # Clear the mailbox
            ::Peers::${name}::clear
            # Remember to suppress/kill the process if it shows up
            # later after we're gone.
            dict set ::peersBlacklist $name true
            after 5000 [list dict unset ::peersBlacklist $name]
        }
    }} $this $name
}
