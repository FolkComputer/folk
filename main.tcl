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
    proc tryRunInSerializedEnvironment {body env} {
        try {
            runInSerializedEnvironment $body $env
        } on error err {
            if {[dict exists $env this]} {
                Say [dict get $env this] has error $err with info $::errorInfo
                puts stderr "$::nodename: Error in [dict get $env this], match $::matchId: $err\n$::errorInfo"
            } else {
                Say $::matchId has error $err with info $::errorInfo
                puts stderr "$::nodename: Error in match $::matchId: $err\n$::errorInfo"
            }
        }
    }
}
set ::logsize -1 ;# Hack to keep metrics working

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
    if {[lindex $args end-1] eq "environment"} {
        set body [lindex $args end-3]
        set pattern [lreplace $args end-3 end]
        set environment [lindex $args end]
    } else {
        set body [lindex $args end]
        set pattern [lreplace $args end end]
        set environment [uplevel Evaluator::serializeEnvironment]
    }
    set wordsWillBeBound [list]
    set negate false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set word [lindex $pattern $i]
        if {$word eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingWord [lindex $remainingPattern $j]
                if {$remainingWord in $wordsWillBeBound} {
                    regexp {^/([^/ ]+)/$} $remainingWord -> remainingVarName
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
                lappend wordsWillBeBound $word
            }
        } elseif {[string index $word 0] eq "\$"} {
            lset pattern $i [uplevel [list subst $word]]
        }
    }

    if {$negate} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        uplevel [list Say when the collected matches for $pattern are /__matches/ $negateBody with environment $environment]
    } else {
        uplevel [list Say when {*}$pattern $body with environment $environment]
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
        Statements::matchAddDestructor $::matchId $body [uplevel Evaluator::serializeEnvironment]

    } else {
        error "Unknown On $event $args"
    }
}

proc After {n unit body} {
    if {$unit eq "milliseconds"} {
        set env [uplevel Evaluator::serializeEnvironment]
        after $n [list apply {{body env} {
            Evaluator::tryRunInSerializedEnvironment $body $env
            Step
        }} $body $env]
    } else { error }
}
set ::committed [dict create]
proc Commit {args} {
    upvar this this
    set body [lindex $args end]
    set key [list Commit [expr {[info exists this] ? $this : "<unknown>"}] {*}[lreplace $args end end]]

    set code [list Evaluator::tryRunInSerializedEnvironment $body [uplevel Evaluator::serializeEnvironment]]
    Assert $key has program code $code
    if {[dict exists $::committed $key] && [dict get $::committed $key] ne $code} {
        Retract $key has program code [dict get $::committed $key]
    }
    dict set ::committed $key $code
}

proc StepImpl {} { Evaluator::Evaluate }

set ::nodename "[info hostname]-[pid]"

namespace eval Peers {}
set ::stepCount 0
set ::stepTime "none"
proc Step {} {
    if {[uplevel Evaluator::isRunningInSerializedEnvironment]} {
        set env [uplevel Evaluator::serializeEnvironment]
    }

    incr ::stepCount
    Assert $::nodename has step count $::stepCount
    Retract $::nodename has step count [expr {$::stepCount - 1}]
    set ::stepTime [time {StepImpl}]

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }

    foreach peer [namespace children Peers] {
        namespace eval $peer {
            if {[info exists shareStatements]} {
                variable prevShareStatements $shareStatements
            } else {
                variable prevShareStatements [list]
            }

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
            foreach m [Statements::findMatches [list /someone/ wishes $::nodename shares statements like /pattern/]] {
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
        }
    }

    if {[uplevel Evaluator::isRunningInSerializedEnvironment]} {
        Evaluator::deserializeEnvironment $env [uplevel {namespace current}]
    }
}

source "lib/math.tcl"


# this defines $this in the contained scopes
# it's also used to implement Commit
Assert when /this/ has program code /__code/ {
    eval $__code
}

if {[info exists ::entry]} {
    # This all only runs if we're in a primary Folk process; we don't
    # want it to run in subprocesses (which also run main.tcl).

    Assert when /peer/ shares statements /statements/ with sequence number /gen/ {
        foreach stmt $statements { Say {*}$stmt }
    }

    source "lib/process.tcl"
    source "./web.tcl"
    source $::entry
}
