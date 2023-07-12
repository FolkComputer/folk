if {$tcl_version eq 8.5} { error "Don't use Tcl 8.5 / macOS system Tcl. Quitting." }

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set ::isLaptop [expr {$tcl_platform(os) eq "Darwin" ||
                          ([info exists ::env(XDG_SESSION_TYPE)] &&
                           $::env(XDG_SESSION_TYPE) ne "tty")}]
    if {[info exists ::env(FOLK_ENTRY)]} {
        set ::entry $::env(FOLK_ENTRY)
    } elseif {$::isLaptop} {
        set ::entry "laptop.tcl"
    } else {
        set ::entry "pi/pi.tcl"
    }
}

source "lib/c.tcl"
source "lib/trie.tcl"
source "lib/evaluator.tcl"
namespace eval Evaluator {
    source "lib/environment.tcl"
    proc tryRunInSerializedEnvironment {lambda env} {
        try {
            runInSerializedEnvironment $lambda $env
        } on error err {
            set this ""
            for {set i 0} {$i < [llength [lindex $lambda 0]]} {incr i} {
                if {[lindex $lambda 0 $i] eq "this"} {
                    set this [lindex $env $i]
                    break
                }
            }
            if {$this ne ""} {
                Say $this has error $err with info $::errorInfo
                puts stderr "$::thisProcess: Error in $this, match $::matchId: $err\n$::errorInfo"
            } else {
                Say $::matchId has error $err with info $::errorInfo
                puts stderr "$::thisProcess: Error in match $::matchId: $err\n$::errorInfo"
            }
        }
    }
}
set ::logsize -1 ;# Hack to keep metrics working

source "lib/language.tcl"

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {
    if {[lindex $args 0] eq "when" && [lindex $args end-1] ne "environment"} {
        set args [list {*}$args with environment {}]
    }
    Evaluator::LogWriteAssert $args
}
proc Retract {args} { Evaluator::LogWriteRetract $args }

# invoke from within a When context, add dependent statements
proc Say {args} { Evaluator::LogWriteSay $::matchId $args }
proc Claim {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args] }
proc Wish {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args] }

proc When {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]
    if {[lindex $pattern 0] eq "(non-capturing)"} {
        set argNames [list this]; set argValues [list [uplevel {set this}]]
        set pattern [lreplace $pattern 0 0]
    } else {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
    }

    set varNamesWillBeBound [list]
    set negate false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set word [lindex $pattern $i]
        if {$word eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingWord [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingWord -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            set body [list When {*}$remainingPattern $body]
            break

        } elseif {[set varName [trie scanVariable $word]] != "false"} {
            if {$varName in $statement::blanks} {
            } elseif {$varName in $statement::negations} {
                # Rewrite this entire clause to be negated.
                set negate true
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                lappend varNamesWillBeBound $varName
            }
        } elseif {[trie startsWithDollarSign $word]} {
            lset pattern $i [uplevel [list subst $word]]
        }
    }

    if {$negate} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        uplevel [list Say when the collected matches for $pattern are /__matches/ [list [list {*}$argNames __matches] $negateBody] with environment $argValues]
    } else {
        lappend argNames {*}$varNamesWillBeBound
        uplevel [list Say when {*}$pattern [list $argNames $body] with environment $argValues]
    }
}
proc Every {event args} {
    if {$event eq "time"} {
        set body [lindex $args end]
        set pattern [lreplace $args end end]
        set level 0
        foreach word $pattern { if {$word eq "&"} {incr level} }
        uplevel [list When {*}$pattern "$body\nEvaluator::Unmatch $level"]
    }
}

proc On {event args} {
    if {$event eq "process"} {
        if {[llength $args] == 2} {
            lassign $args name body
        } elseif {[llength $args] == 1} {
            # Generate a unique name.
            set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
            set subprocessId [uplevel {incr __subprocessId}]
            set name "${this}-${::matchId}-${subprocessId}"
            set body [lindex $args 0]
        }
        # Serialize the lexical environment at the callsite so we can
        # send that to the subprocess.
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        uplevel [list On-process $name [list apply [list $argNames $body] {*}$argValues]]

    } elseif {$event eq "unmatch"} {
        set body [lindex $args 0]
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        Statements::matchAddDestructor $::matchId [list $argNames $body] $argValues

    } else {
        error "Unknown On $event $args"
    }
}

proc After {n unit body} {
    if {$unit eq "milliseconds"} {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        after $n [list apply [list $argNames [subst {
            $body
            Step
        }]] {*}$argValues]
    } else { error }
}
set ::committed [dict create]
set ::toCommit [dict create]
proc Commit {args} {
    set body [lindex $args end]
    set key [list Commit [uplevel {expr {[info exists this] ? $this : "<unknown>"}}] {*}[lreplace $args end end]]
    if {$body eq ""} {
        dict set ::toCommit $key $body
    } else {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        set lambda [list {this} [list apply [list $argNames $body] {*}$argValues]]
        dict set ::toCommit $key $lambda
    }

    after idle Step
}

set ::stepCount 0
set ::stepTime "none"
source "lib/peer.tcl"
proc StepImpl {} {
    incr ::stepCount
    Assert $::thisProcess has step count $::stepCount
    Retract $::thisProcess has step count [expr {$::stepCount - 1}]

    while {[dict size $::toCommit] > 0 || ![Evaluator::LogIsEmpty]} {
        dict for {key lambda} $::toCommit {
            if {$lambda ne ""} {
                Assert $key has program $lambda
            }
            if {[dict exists $::committed $key] && [dict get $::committed $key] ne $lambda} {
                Retract $key has program [dict get $::committed $key]
            }
            if {$lambda ne ""} {
                dict set ::committed $key $lambda
            }
        }
        set ::toCommit [dict create]
        Evaluator::Evaluate
    }

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }

    foreach peerNs [namespace children ::Peers] {
        apply [list {peer} {
            variable connected
            if {!$connected} { return }

            set shareStatements [clauseset create]
            set shareAllWishes [expr {[llength [Statements::findMatches [list /someone/ wishes $::thisProcess shares all wishes]]] > 0}]
            set shareAllClaims [expr {[llength [Statements::findMatches [list /someone/ wishes $::thisProcess shares all claims]]] > 0}]
            dict for {_ stmt} [Statements::all] {
                if {($shareAllWishes && [lindex [statement clause $stmt] 1] eq "wishes") ||
                    ($shareAllClaims && [lindex [statement clause $stmt] 1] eq "claims")} {
                    clauseset add shareStatements [statement clause $stmt]
                }
            }

            set matches [Statements::findMatches [list /someone/ wishes $::thisProcess shares statements like /pattern/]]
            lappend matches {*}[Statements::findMatches [list /someone/ wishes $peer receives statements like /pattern/]]
            foreach m $matches {
                set pattern [dict get $m pattern]
                foreach match [Statements::findMatches $pattern] {
                    set id [lindex [dict get $match __matcheeIds] 0]
                    set clause [statement clause [Statements::get $id]]
                    clauseset add shareStatements $clause
                }
            }

            if {[clauseset size $shareStatements] > 0} {
                run [list apply {{process receivedStatements} {
                    upvar chan chan
                    Commit $chan statements {
                        Claim $process is sharing statements $receivedStatements
                    }
                }} $::thisProcess [clauseset clauses $shareStatements]]
            }
        } $peerNs] [namespace tail $peerNs]
    }
}
proc Step {} {
    if {[dict size $::toCommit] > 0 || ![Evaluator::LogIsEmpty]} {
        set ::stepTime [time StepImpl]
    }
}

source "lib/math.tcl"


# this defines $this in the contained scopes
# it's also used to implement Commit
Assert when /this/ has program /__program/ {{this __program} {
    apply $__program $this
}}
# For backward compat(?):
Assert when /__this/ has program code /__programCode/ {{__this __programCode} {
    Claim $__this has program [list {this} $__programCode]
}}

Assert when /someone/ is sharing statements /statements/ {{statements} {
    foreach stmt $statements { Say {*}$stmt }
}}

set ::thisNode "[info hostname]"
set ::nodename $::thisNode ;# for backward compat

namespace eval ::Heap {
    # Folk has a shared heap among all processes on a given node
    # (physical machine).

    # Memory allocated from the Folk heap should be accessible, at
    # exactly the same virtual address, from any Folk process.

    proc init {} {
        variable cc [c create]
        $cc include <sys/mman.h>
        $cc include <sys/stat.h>
        $cc include <fcntl.h>
        $cc include <unistd.h>
        $cc include <stdlib.h>
        $cc code {
            size_t folkHeapSize = 100000000; // 100MB
            uint8_t* folkHeapBase;
            uint8_t* _Atomic folkHeapPointer;
        }
        # The memory mapping of the heap will be inherited by all
        # subprocesses, since it's established before the creation of
        # the zygote.
        $cc proc folkHeapMount {} void {
            int fd = shm_open("/folk-heap", O_RDWR | O_CREAT, S_IROTH | S_IWOTH | S_IRUSR | S_IWUSR);
            ftruncate(fd, folkHeapSize);
            folkHeapBase = (uint8_t*) mmap(0, folkHeapSize,
                                           PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (folkHeapBase == NULL) {
                fprintf(stderr, "heapMount: failed"); exit(1);
            }
            folkHeapPointer = folkHeapBase;
        }
        $cc proc folkHeapAlloc {size_t sz} void* {
            if (folkHeapPointer + sz > folkHeapBase + folkHeapSize) {
                fprintf(stderr, "heapAlloc: out of memory"); exit(1);
            }
            void* ptr = folkHeapPointer;
            folkHeapPointer = folkHeapPointer + sz;
            return (void*) ptr;
        }
        if {$::tcl_platform(os) eq "Linux"} {
            $cc cflags -lrt
            c loadlib [lindex [exec /usr/sbin/ldconfig -p | grep librt.so | head -1] end]
        }
        $cc compile
        folkHeapMount
    }
}
Heap::init

if {[info exists ::entry]} {
    source "lib/process.tcl"
    Zygote::init

    # Everything below here only runs if we're in the primary Folk
    # process.
    set ::thisProcess $::thisNode

    proc ::loadVirtualPrograms {} {
        set ::rootVirtualPrograms [dict create]
        proc loadProgram {programFilename} {
            # this is a proc so its variables don't leak
            set fp [open $programFilename r]
            dict set ::rootVirtualPrograms $programFilename [read $fp]
            close $fp
        }
        foreach programFilename [list {*}[glob virtual-programs/*.folk] \
                                     {*}[glob -nocomplain "user-programs/[info hostname]/*.folk"]] {
            loadProgram $programFilename
        }
        Assert $::thisNode is providing root virtual programs $::rootVirtualPrograms

        # So we can retract them all at once if some other node connects and
        # wants to impose its root virtual programs:
        Assert when the collected matches for \
                    [list /node/ is providing root virtual programs /rootVirtualPrograms/] \
                    are /roots/ {{roots} {

            if {[llength $roots] == 0} {
                error "No root virtual programs available for entry Tcl node."
            }

            # Are there foreign root virtual programs that should take priority over ours?
            foreach root $roots {
                if {[dict get $root node] ne $::thisNode} {
                    set chosenRoot $root
                    break
                }
            }
            if {![info exists chosenRoot]} {
                # Default to first in the list if no foreign root.
                set chosenRoot [lindex $roots 0]
            }

            dict for {programFilename programCode} [dict get $chosenRoot rootVirtualPrograms] {
                Say [dict get $chosenRoot node] claims $programFilename has program code $programCode
            }
        }}

        # Watch for virtual-programs/ changes.
        try {
            set fd [open "|fswatch virtual-programs" r]
            fconfigure $fd -buffering line
            fileevent $fd readable [list apply {{fd} {
                set changedFilename [file tail [gets $fd]]
                if {[string index $changedFilename 0] eq "." ||
                    [string index $changedFilename 0] eq "#" ||
                    [file extension $changedFilename] ne ".folk"} {
                    return
                }
                set changedProgramName "virtual-programs/$changedFilename"
                puts "$changedProgramName updated, reloading."

                set fp [open $changedProgramName r]; set programCode [read $fp]; close $fp
                EditVirtualProgram $changedProgramName $programCode
            }} $fd]
        } on error err {
            puts stderr "Warning: could not invoke `fswatch` ($err)."
            puts stderr "Will not watch virtual-programs for changes."
        }
    }
    proc ::EditVirtualProgram {programName programCode} {
        set oldRootVirtualPrograms $::rootVirtualPrograms
        if {[dict exists $oldRootVirtualPrograms $programName] &&
            [dict get $oldRootVirtualPrograms $programName] eq $programCode} {
            # Code hasn't changed.
            return
        }
        dict set ::rootVirtualPrograms $programName $programCode

        Assert $::thisNode is providing root virtual programs $::rootVirtualPrograms
        Retract $::thisNode is providing root virtual programs $oldRootVirtualPrograms
        Step
    }

    source "./web.tcl"
    source $::entry
}
