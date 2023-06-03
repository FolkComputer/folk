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
                puts stderr "$::nodename: Error in $this, match $::matchId: $err\n$::errorInfo"
            } else {
                Say $::matchId has error $err with info $::errorInfo
                puts stderr "$::nodename: Error in match $::matchId: $err\n$::errorInfo"
            }
        }
    }
}
set ::logsize -1 ;# Hack to keep metrics working

proc fn {name argNames body} {
    uplevel [list set ^$name [list $argNames $body]]
}
rename unknown _original_unknown
proc unknown {name args} {
    if {[uplevel [list info exists ^$name]]} {
        apply [uplevel [list set ^$name]] {*}$args
    } else {
        uplevel [list _original_unknown $name {*}$args]
    }
}

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
        set argNames [list]; set argValues [list]
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

        } elseif {[regexp {^/([^/ ]+)/$} $word -> varName]} {
            if {$varName in $statement::blanks} {
            } elseif {$varName in $statement::negations} {
                # Rewrite this entire clause to be negated.
                set negate true
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                lappend varNamesWillBeBound $varName
            }
        } elseif {[string index $word 0] eq "\$"} {
            lset pattern $i [uplevel [list subst $word]]
        }
    }
    lappend argNames {*}$varNamesWillBeBound

    if {$negate} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        uplevel [list Say when the collected matches for $pattern are /__matches/ [list [list {*}$argNames __matches] $negateBody] with environment $argValues]
    } else {
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
            set name "${::matchId}-process"
            set body [lindex $args 0]
        }
        uplevel [list On-process $name $body]

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
proc Commit {args} {
    upvar this this
    set body [lindex $args end]
    set key [list Commit [expr {[info exists this] ? $this : "<unknown>"}] {*}[lreplace $args end end]]
    lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
    set lambda [list {this} [list apply [list $argNames $body] {*}$argValues]]
    Assert $key has program $lambda
    if {[dict exists $::committed $key] && [dict get $::committed $key] ne $lambda} {
        Retract $key has program [dict get $::committed $key]
    }
    dict set ::committed $key $lambda
}

proc StepImpl {} { Evaluator::Evaluate }

set ::nodename "[info hostname]-[pid]"

namespace eval Peers {}
set ::stepCount 0
set ::stepTime "none"
proc Step {} {
    incr ::stepCount
    Assert $::nodename has step count $::stepCount
    Retract $::nodename has step count [expr {$::stepCount - 1}]
    set ::stepTime [time {StepImpl}]

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }

    foreach peerNs [namespace children Peers] {
        apply [list {peer} {
            variable shareStatements [list]
            if {[llength [Statements::findMatches [list /someone/ wishes $::nodename shares all statements]]] > 0} {
                dict for {_ stmt} [Statements::all] {
                    lappend shareStatements [statement clause $stmt]
                }
            } elseif {[llength [Statements::findMatches [list /someone/ wishes $::nodename shares all claims]]] > 0} {
                dict for {_ stmt} [Statements::all] {
                    if {[lindex [statement clause $stmt] 1] eq "claims"} {
                        lappend shareStatements [statement clause $stmt]
                    }
                }
            }

            set matches [Statements::findMatches [list /someone/ wishes $::nodename shares statements like /pattern/]]
            lappend matches {*}[Statements::findMatches [list /someone/ wishes $peer receives statements like /pattern/]]
            foreach m $matches {
                set pattern [dict get $m pattern]
                foreach match [Statements::findMatches $pattern] {
                    set id [lindex [dict get $match __matcheeIds] 0]
                    set clause [statement clause [Statements::get $id]]
                    lappend shareStatements $clause
                }
            }

            incr sequenceNumber
            run [subst {
                Assert $::nodename shares statements {$shareStatements} with sequence number $sequenceNumber
                Retract $::nodename shares statements /any/ with sequence number [expr {$sequenceNumber - 1}]
                Step
            }]
        } $peerNs] [namespace tail $peerNs]
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

if {[info exists ::entry]} {
    # This all only runs if we're in a primary Folk process; we don't
    # want it to run in subprocesses (which also run main.tcl).

    Assert when /peer/ shares statements /statements/ with sequence number /gen/ {{peer statements gen} {
        foreach stmt $statements { Say {*}$stmt }
    }}

    source "lib/process.tcl"
    source "./web.tcl"
    source $::entry
}
