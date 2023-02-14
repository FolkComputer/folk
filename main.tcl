if {$tcl_version eq 8.5} { error "Don't use Tcl 8.5 / macOS system Tcl. Quitting." }

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set ::isLaptop [expr {$tcl_platform(os) eq "Darwin" || [info exists ::env(DISPLAY)]}]
    if {[info exists ::env(FOLK_ENTRY)]} {
        set ::entry $::env(FOLK_ENTRY)
    } elseif {$::isLaptop} {
        set ::entry "laptop.tcl"
    } else {
        set ::entry "pi/pi.tcl"
    }
}


source "play/reaction-oriented-incremental-evaluator-play.tcl"

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

    foreach peer [namespace children Peers] {
        namespace eval $peer {
            if {[info exists shareStatements]} {
                variable prevShareStatements $shareStatements
            } else {
                variable prevShareStatements [list]
            }

            variable shareStatements [list]
            foreach m [Statements::findMatches [list /someone/ wishes $::nodename shares statements like /pattern/]] {
                set pattern [dict get $m pattern]
                foreach id [trie lookup $Statements::statementClauseToId $pattern] {
                    set clause [statement clause [Statements::get $id]]
                    set match [statement unify $pattern $clause]
                    if {$match != false} {
                        lappend shareStatements [list {*}$clause]
                    }
                }
            }

            incr sequenceNumber
            run [subst {
                Assert $::nodename shares statements {$shareStatements} with sequence number $sequenceNumber
                Retract $::nodename shares statements /any/ with sequence number [expr {$sequenceNumber - 1}]
            }]
        }
    }
}
Assert when /peer/ shares statements /statements/ with sequence number /gen/ {
    foreach stmt $statements { Say {*}$stmt }
}

source "lib/math.tcl"

if {[info exists ::entry]} {
    # This all only runs if we're in a primary Folk process; we don't
    # want it to run in subprocesses (which also run main.tcl).

    # this defines $this in the contained scopes
    Assert when /this/ has program code /__code/ {
        if {[catch $__code err] == 1} {
            puts "$::nodename: Error in $this: $err\n$::errorInfo"
        }
    }
    source "lib/process.tcl"
    source "./web.tcl"
    source $::entry
}
