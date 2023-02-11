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

proc d {arg} {
    # puts $arg
}
proc lremove {l val} {
    set posn [lsearch -exact $l $val]
    lreplace $l $posn $posn
}

source "lib/c.tcl"
source "lib/trie.tcl"
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    rename add add_; rename addWithVar add
    rename remove remove_; rename removeWithVar remove
    namespace ensemble create
}

namespace eval statement { ;# statement record type
    namespace export create
    proc create {clause {parentMatchIds {}} {childMatchIds {}}} {
        # clause = [list the fox is out]
        # parentMatchIds = [dict create 503 true 208 true]
        # childMatchIds = [dict create 101 true 433 true]
        return [dict create \
                    clause $clause \
                    parentMatchIds $parentMatchIds \
                    childMatchIds $childMatchIds]
    }

    namespace export clause parentMatchIds childMatchIds
    proc clause {stmt} { dict get $stmt clause }
    proc parentMatchIds {stmt} { dict get $stmt parentMatchIds }
    proc childMatchIds {stmt} { dict get $stmt childMatchIds }

    namespace export short
    proc short {stmt} {
        set lines [split [clause $stmt] "\n"]
        set line [lindex $lines 0]
        if {[string length $line] > 80} {set line "[string range $line 0 80]..."}
        dict with stmt { format "{%s} %s {%s}" $parentMatchIds $line $childMatchIds }
    }

    namespace ensemble create
}

namespace eval Statements { ;# singleton Statement store
    variable statements [dict create] ;# Dict<StatementId, Statement>
    variable nextStatementId 1
    variable statementClauseToId [trie create] ;# Trie<StatementClause, StatementId>

    # Dict<MatchId, [parentStatementIds: List<StatementId>, childStatementIds: List<StatementId>]>
    variable matches [dict create]
    variable nextMatchId 1

    proc reset {} {
        variable statements
        variable nextStatementId
        variable statementClauseToId
        set statements [dict create]
        set nextStatementId 1
        set statementClauseToId [trie create]
        variable matches; variable nextMatchId
        set matches [dict create]
        set nextMatchId 1
    }

    proc addMatch {parentStatementIds} {
        variable matches
        variable nextMatchId
        set matchId [incr nextMatchId]
        set match [dict create \
                       parentStatementIds $parentStatementIds \
                       childStatementIds [list] \
                       destructor {}]
        dict set matches $matchId $match
        foreach parentStatementId $parentStatementIds {
            dict with Statements::statements $parentStatementId {
                dict set childMatchIds $matchId true
            }
        }
        set matchId
    }
    proc matchExists {id} { variable matches; dict exists $matches $id }

    proc add {clause {newParentMatchIds {{} 1}}} {
        # empty set in newParentMatchIds = an assertion
 
        variable statements
        variable nextStatementId
        variable statementClauseToId

        # is this clause already present in the existing statement set?
        set ids [trie lookup $statementClauseToId $clause]
        if {[llength $ids] == 1} {
            set id [lindex $ids 0]
        } elseif {[llength $ids] == 0} {
            set id false
        } else {
            error "WTF: Looked up {$clause}"
        }

        set isNewStatement [expr {$id eq false}]
        if {$isNewStatement} {
            set id [incr nextStatementId]
            set stmt [statement create $clause $newParentMatchIds]
            dict set statements $id $stmt
            trie add statementClauseToId $clause $id
        } else {
            dict with statements $id {
                dict for {newParentMatchId count} $newParentMatchIds {
                    dict incr parentMatchIds $newParentMatchId $count
                }
            }
        }

        dict for {parentMatchId _} $newParentMatchIds {
            if {$parentMatchId eq {}} { continue }
            dict with Statements::matches $parentMatchId {
                lappend childStatementIds $id
            }
        }

        list $id $isNewStatement
    }
    proc exists {id} { variable statements; return [dict exists $statements $id] }
    proc get {id} { variable statements; return [dict get $statements $id] }
    proc remove {id} {
        variable statements
        variable statementClauseToId
        set clause [statement clause [get $id]]
        dict unset statements $id
        trie remove statementClauseToId $clause
    }
    proc size {} { variable statements; return [dict size $statements] }
    proc countMatches {} {
        variable statements
        set count 0
        dict for {_ stmt} $statements {
            set count [expr {$count + [dict size [statement parentMatchIds $stmt]]}]
        }
        return $count
    }
    
    proc unify {a b} {
        if {[llength $a] != [llength $b]} { return false }

        set match [dict create]
        for {set i 0} {$i < [llength $a]} {incr i} {
            set aWord [lindex $a $i]
            set bWord [lindex $b $i]
            if {[regexp {^/([^/ ]+)/$} $aWord -> aVarName]} {
                dict set match $aVarName $bWord
            } elseif {[regexp {^/([^/ ]+)/$} $bWord -> bVarName]} {
                dict set match $bVarName $aWord
            } elseif {$aWord != $bWord} {
                return false
            }
        }
        return $match
    }
    proc findMatches {pattern} {
        variable statementClauseToId
        variable statements
        # Returns a list of bindings like
        # {{name Bob age 27 __matcheeId 6} {name Omar age 28 __matcheeId 7}}

        set matches [list]
        foreach id [trie lookup $statementClauseToId $pattern] {
            set match [unify $pattern [statement clause [get $id]]]
            if {$match != false} {
                dict set match __matcheeId $id
                lappend matches $match
            }
        }

        return $matches
    }

    proc all {} { variable statements; set statements }
    proc print {} {
        variable statements
        puts "Statements"
        puts "=========="
        dict for {id stmt} $statements { puts "$id: [statement short $stmt]" }
    }
    proc dot {} {
        variable statements
        set dot [list]
        dict for {id stmt} $statements {
            lappend dot "subgraph cluster_$id {"
            lappend dot "color=lightgray;"

            set label [statement clause $stmt]
            set label [join [lmap line [split $label "\n"] {
                expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
            }] "\n"]
            set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
            lappend dot "$id \[label=\"$id: $label\"\];"

            dict for {matchId parents} [statement parentMatchIds $stmt] {
                lappend dot "\"$id $matchId\" \[label=\"$id#$matchId: $parents\"\];"
                lappend dot "\"$id $matchId\" -> $id;"
            }

            lappend dot "}"
            dict for {child _} [statement childMatchIds $stmt] {
                lappend dot "$id -> \"$child\";"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
    }
}

# source "play/c-statements.tcl"

set ::log [list]

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

# invoke from within a When context, add dependent statements
proc Say {args} {
    set ::log [linsert $::log 0 [list Say $::matchId $args]]
}
proc Claim {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args] }
proc Wish {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args] }

source "lib/environment.tcl"
proc When {args} {
    uplevel [list Say when {*}$args with environment [serializeEnvironment]]
}

proc On {event args} {
    if {$event eq "process"} {
        lassign $args name body
        uplevel [list On-process $name $body]

    } elseif {$event eq "unmatch"} {
        set body [lindex $args 0]
        dict set Statements::matches $::matchId destructor [list $body [serializeEnvironment]]
    }
}
proc Do {args} { lappend ::log [list Do $::matchId $args {}] }
proc Before {event body} {
    if {$event eq "convergence"} {
        lappend ::log [list Do $::matchId $body [serializeEnvironment]]
    }
}

proc StepImpl {} {
    # should this do reduction of assert/retract ?
    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lindex $clause 0] == "when"} {
            # is this a When? match it against existing statements
            # when the time is /t/ { ... } with environment /env/ -> the time is /t/
            set unwhenizedClause [lreplace [lreplace $clause end-3 end] 0 0]
            set matches [concat [Statements::findMatches $unwhenizedClause] \
                             [Statements::findMatches [list /someone/ claims {*}$unwhenizedClause]]]
            set body [lindex $clause end-3]
            set env [lindex $clause end]
            foreach match $matches {
                set ::matchId [Statements::addMatch [list $id [dict get $match __matcheeId]]]
                set __env [dict merge \
                               $env \
                               $match]
                runInSerializedEnvironment $body $__env
            }
        }

        # match this statement against existing whens
        # the time is 3 -> when the time is 3 /__body/ with environment /__env/
        proc whenize {clause} { return [list when {*}$clause /__body/ with environment /__env/] }
        set matches [Statements::findMatches [whenize $clause]]
        if {[Statements::unify [lrange $clause 0 1] [list /someone/ claims]] != false} {
            # Omar claims the time is 3 -> when the time is 3 /__body/ with environment /__env/
            lappend matches {*}[Statements::findMatches [whenize [lrange $clause 2 end]]]
        }
        foreach match $matches {
            set ::matchId [Statements::addMatch [list $id [dict get $match __matcheeId]]]
            set __env [dict merge \
                           [dict get $match __env] \
                           $match]
            runInSerializedEnvironment [dict get $match __body] $__env
        }
    }
    proc reactToStatementRemoval {id} {
        # unset all things downstream of statement
        set childMatchIds [statement childMatchIds [Statements::get $id]]
        dict for {matchId _} $childMatchIds {
            if {![dict exists $Statements::matches $matchId]} { continue } ;# if was removed earlier

            dict with Statements::matches $matchId {
                # this match will be dead, so remove the match from the
                # other parents of the match
                foreach parentStatementId $parentStatementIds {
                    if {![Statements::exists $parentStatementId]} { continue }
                    dict with Statements::statements $parentStatementId {
                        dict unset childMatchIds $matchId
                    }
                }

                foreach childStatementId $childStatementIds {
                    if {![Statements::exists $childStatementId]} { continue }
                    dict with Statements::statements $childStatementId {
                        dict unset parentMatchIds $matchId

                        # is this child out of parent matches? => it's dead
                        if {[dict size $parentMatchIds] == 0} {
                            reactToStatementRemoval $childStatementId
                            Statements::remove $childStatementId
                            set childStatementIds [lremove $childStatementIds $childStatementId]
                        }
                    }
                }

                if {$destructor ne ""} { runInSerializedEnvironment {*}$destructor }
            }
            dict unset Statements::matches $matchId
        }
    }
    if {[namespace which Statements::reactToStatementRemoval] ne ""} {
        rename reactToStatementAddition ""
        rename reactToStatementRemoval ""
        namespace import Statements::reactToStatementAddition
        namespace import Statements::reactToStatementRemoval
    }
    proc reactToStatementRetraction {id} {
        dict with Statements::statements $id {
            dict incr parentMatchIds {} -1
            if {[dict get $parentMatchIds {}] == 0} {
                reactToStatementRemoval $id
                Statements::remove $id
            }
        }
    }

    # d ""
    # d "Step:"
    # d "-----"

    # puts "Now processing log: $::log"
    set ::logsize [llength $::log]
    while {[llength $::log]} {
        # TODO: make this log-shift more efficient?
        set entry [lindex $::log 0]
        set ::log [lreplace $::log 0 0]

        set op [lindex $entry 0]
        # d "$op: [string map {\n { }} [string range $entry 0 100]]"
        if {$op eq "Assert"} {
            set clause [lindex $entry 1]
            # insert empty environment if not present
            if {[lindex $clause 0] eq "when" && [lrange $clause end-2 end-1] != "with environment"} {
                set clause [list {*}$clause with environment {}]
            }
            lassign [Statements::add $clause] id isNewStatement ;# statement without parents
            if {$isNewStatement} { reactToStatementAddition $id }

        } elseif {$op eq "Retract"} {
            set clause [lindex $entry 1]
            set ids [lmap match [Statements::findMatches $clause] {
                dict get $match __matcheeId
            }]
            foreach id $ids {
                reactToStatementRetraction $id
            }

        } elseif {$op eq "Say"} {
            set parentMatchId [lindex $entry 1]
            set clause [lindex $entry 2]
            lassign [Statements::add $clause [dict create $parentMatchId 1]] id isNewStatement
            if {$isNewStatement} { reactToStatementAddition $id }

        } elseif {$op eq "Do"} {
            lassign $entry _ matchId body env
            if {[Statements::matchExists $matchId]} {
                set ::matchId $matchId
                runInSerializedEnvironment $body $env
            }
        }
    }

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }
}

set ::nodename "[info hostname]-[pid]"

namespace eval Peers {}
set ::stepCount 0
set ::stepTime "none"
proc Step {} {
    incr ::stepCount
    Assert $::nodename has step count $::stepCount
    Retract $::nodename has step count [expr {$::stepCount - 1}]
    set ::stepTime [time {StepImpl}]

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
                    set match [Statements::unify $pattern $clause]
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

set ::collectedMatches [dict create]
Assert when when the collected matches for /clause/ are /matchesVar/ /body/ with environment /e/ {
    set varNames [lmap word $clause {expr {
        [regexp {^/([^/ ]+)/$} $word -> varName] ? $varName : [continue]
    }}]
    When {*}$clause {
        set match [dict create]
        foreach varName $varNames { dict set match $varName [set $varName] }

        dict set ::collectedMatches $clause $match true
        On unmatch {
            if {[dict exists $::collectedMatches $clause]} {
                dict unset ::collectedMatches $clause $match
            }
        }
    }

    When $::nodename has step count /c/ {
        if {[dict exists $::collectedMatches $clause]} {
            set matches [dict get $::collectedMatches $clause]
            Say the collected matches for $clause are [dict keys $matches]
        } else {
            Say the collected matches for $clause are {}
        }
    }
    On unmatch { dict unset ::collectedMatches $clause }
}

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
