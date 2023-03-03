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
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    rename add add_; rename addWithVar add
    rename remove remove_; rename removeWithVar remove
    namespace ensemble create
}

namespace eval statement { ;# statement record type
    # A statement contains a clause (a Tcl list of words), parents (a
    # set of match IDs), and children (a set of match IDs). Sets are
    # Tcl dicts where values are always true.

    namespace export create
    proc create {clause {parents {}} {children {}}} {
        # clause = [list the fox is out]
        # parentMatchIds = [dict create 503 true 208 true]
        # childMatchIds = [dict create 101 true 433 true]
        dict create \
            clause $clause \
            parents $parents \
            children $children
    }

    namespace export clause parents children
    proc clause {stmt} { dict get $stmt clause }
    proc parents {stmt} { dict get $stmt parents }
    proc children {stmt} { dict get $stmt children }

    namespace export unify
    variable blanks [list someone something anyone anything]
    proc unify {a b} {
        variable blanks
        if {[llength $a] != [llength $b]} { return false }

        set match [dict create]
        for {set i 0} {$i < [llength $a]} {incr i} {
            set aWord [lindex $a $i]
            set bWord [lindex $b $i]
            if {[regexp {^/([^/ ]+)/$} $aWord -> aVarName]} {
                if {!($aVarName in $blanks)} {
                    dict set match $aVarName $bWord
                }
            } elseif {[regexp {^/([^/ ]+)/$} $bWord -> bVarName]} {
                if {!($bVarName in $blanks)} {
                    dict set match $bVarName $aWord
                }
            } elseif {$aWord ne $bWord} {
                return false
            }
        }
        set match
    }

    namespace export short
    proc short {stmt} {
        set lines [split [clause $stmt] "\n"]
        set line [lindex $lines 0]
        if {[string length $line] > 80} {set line "[string range $line 0 80]..."}
        format "{%s} %s {%s}" [parents $stmt] $line [children $stmt]
    }

    namespace ensemble create
}

# This singleton match store lets you add and remove matches.
namespace eval Matches {
    namespace eval match { ;# match record type
        namespace export create
        proc create {{parents {}}} {
            dict create \
                parents $parents \
                children [list] \
                destructors [list]
        }

        namespace ensemble create
    }

    # Dict<MatchId, [parents: List<StatementId>, children: List<StatementId>]>
    variable matches [dict create]
    variable nextMatchId 1

    proc add {parents} {
        variable matches
        variable nextMatchId
        set matchId [incr nextMatchId]
        dict set matches $matchId [match create $parents]

        # Add this match as a child to all the statement parents that
        # were passed in.
        foreach parentStatementId $parents {
            dict with Statements::statements $parentStatementId {
                dict set children $matchId true
            }
        }

        set matchId
    }

    proc exists {id} { variable matches; dict exists $matches $id }
}

# This singleton statement store lets you add and remove statements;
# it properly manages the addition and removal of associated edges and
# nodes.
namespace eval Statements {
    variable statements [dict create] ;# Dict<StatementId, Statement>
    variable nextStatementId 1

    variable statementClauseToId [trie create] ;# Trie<StatementClause, StatementId>

    proc exists {id} { variable statements; dict exists $statements $id }
    proc get {id} { variable statements; dict get $statements $id }

    proc add {clause {parents {{} true}}} {
        variable statements
        variable nextStatementId
        variable statementClauseToId
        
        # Is this clause already present in the existing statement set?
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
            set stmt [statement create $clause $parents]
            dict set statements $id $stmt
            trie add statementClauseToId $clause $id
        } else {
            # Add the parent matches that were passed in as parents to
            # the existing statement.
            set addingParents $parents
            dict for {parentMatchId _} $addingParents {
                dict set statements $id parents $parentMatchId true
            }
        }

        # Add this statement as a child to all the parent matches
        # that were passed in.
        dict for {parentMatchId _} $parents {
            if {$parentMatchId eq {}} { continue }
            # if {![Matches::exists $parentMatchId]} { continue }
            dict with Matches::matches $parentMatchId {
                lappend children $id
            }
        }

        list $id $isNewStatement
    }
    proc remove {id} {
        variable statements
        variable statementClauseToId
        set clause [statement clause [get $id]]
        dict unset statements $id
        trie remove statementClauseToId $clause
    }
    proc size {} { variable statements; dict size $statements }

    # TODO: rename to something that doesn't have word 'Matches'
    proc findMatches {pattern} {
        variable statementClauseToId
        variable statements
        # Returns a list of bindings like
        # {{name Bob age 27 __matcheeIds {6}} {name Omar age 28 __matcheeIds {7}}}

        set matches [list]
        foreach id [trie lookup $statementClauseToId $pattern] {
            set stmt [get $id]

            set match [statement unify $pattern [statement clause $stmt]]
            if {$match != false} {
                dict set match __matcheeIds [list $id]
                lappend matches $match
            }
        }
        set matches
    }
    proc findMatchesJoining {patterns {bindings {}}} {
        if {[llength $patterns] == 0} {
            return [list $bindings]
        }

        # patterns = [list {/p/ is a person} {/p/ lives in /place/}]

        # Split first pattern from the other patterns
        set otherPatterns [lassign $patterns firstPattern]
        # Do substitution of bindings into first pattern
        set substitutedFirstPattern [list]
        foreach word $firstPattern {
            if {[regexp {^/([^/ ]+)/$} $word -> varName] &&
                [dict exists $bindings $varName]} {
                lappend substitutedFirstPattern [dict get $bindings $varName]
            } else {
                lappend substitutedFirstPattern $word
            }
        }

        set matcheeIds [if {[dict exists $bindings __matcheeIds]} {
            dict get $bindings __matcheeIds
        } else { list }]

        set matches [list]
        set matchesForFirstPattern [findMatches $substitutedFirstPattern]
        lappend matchesForFirstPattern {*}[findMatches [list /someone/ claims {*}$substitutedFirstPattern]]
        foreach matchBindings $matchesForFirstPattern {
            dict lappend matchBindings __matcheeIds {*}$matcheeIds
            set matchBindings [dict merge $bindings $matchBindings]
            lappend matches {*}[findMatchesJoining $otherPatterns $matchBindings]
        }
        set matches
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
            lappend dot "s$id \[label=\"s$id: $label\"\];"

            dict for {matchId _} [statement parents $stmt] {
                lappend dot "m$matchId \[label=\"m$matchId\"\];"
                lappend dot "m$matchId -> s$id;"
            }

            lappend dot "}"
            dict for {matchId _} [statement children $stmt] {
                lappend dot "s$id -> m$matchId;"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
    }
    proc print {} {
        variable statements
        dict for {_ stmt} $statements {
            puts [statement short $stmt]
        }
    }
}

namespace eval Evaluator {
    variable log [list]

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

    # Given a StatementPattern, tells you all the reactions to run
    # when a matching statement is added to / removed from the
    # database. StatementId is the ID of the statement that wanted to
    # react.
    #
    # For example, if you add `When the time is /t/`, it will register
    # a reaction to the addition and removal of statements matching
    # the pattern `the time is /t/`.
    #
    # Trie<StatementPattern + StatementId, Reaction>
    variable reactionsToStatementAddition [trie create]
    # Used to quickly remove reactions when the reacting statement is removed:
    # Dict<StatementId, List<StatementPattern + StatementId>>
    variable reactionPatternsOfReactingId [dict create]
    # A reaction is a runnable script that gets passed the reactingId
    # and the ID of the matching statement.
    proc addReaction {pattern reactingId reaction} {
        variable reactionsToStatementAddition
        trie add reactionsToStatementAddition [list {*}$pattern $reactingId] $reaction
        variable reactionPatternsOfReactingId
        dict lappend reactionPatternsOfReactingId $reactingId [list {*}$pattern $reactingId]
    }
    proc removeAllReactions {reactingId} {
        variable reactionPatternsOfReactingId
        if {![dict exists $reactionPatternsOfReactingId $reactingId]} { return }

        variable reactionsToStatementAddition
        foreach reactionPattern [dict get $reactionPatternsOfReactingId $reactingId] {
            trie remove reactionsToStatementAddition $reactionPattern
        }
        dict unset reactionPatternsOfReactingId $reactingId
    }

    proc reactToStatementAdditionThatMatchesWhen {whenId whenPattern otherWhenPatterns
                                                  statementId statementClause} {
        if {![Statements::exists $whenId]} {
            removeAllReactions $whenId
            return
        }
        set when [Statements::get $whenId]

        set bindings [statement unify \
                          $whenPattern \
                          $statementClause]
        if {$bindings eq false} { return }
        dict set bindings __matcheeIds [list $statementId]

        set matches [Statements::findMatchesJoining \
                         $otherWhenPatterns \
                         $bindings]
        foreach bindings $matches {
            set ::matchId [Matches::add [list $whenId {*}[dict get $bindings __matcheeIds]]]
            set body [lindex [statement clause $when] end-3]
            set env [lindex [statement clause $when] end]
            set env [dict merge $env $bindings]
            tryRunInSerializedEnvironment $body $env
        }
    }
    proc recollect {collectId} {
        # Called when a statement of a pattern that someone is
        # collecting has been added or removed.

        set collect [Statements::get $collectId]
        set children [statement children $collect]
        if {[dict size $children] > 1} {
            error "Collect $collectId has more than 1 match: {$children}"
        } elseif {[dict size $children] == 1} {
            # Delete the existing match child.
            set childMatchId [lindex [dict keys $children] 0]
            # Delete the first destructor (which does a recollect) before doing the removal.
            dict set Matches::matches $childMatchId destructors [lreplace [dict get $Matches::matches $childMatchId destructors] 0 0]
            reactToMatchRemoval $childMatchId
            dict unset Matches::matches $childMatchId

            dict set Statements::statements $collectId children [dict create]
        }

        set clause [statement clause $collect]
        set patterns [lsplit [lindex $clause 5] &]
        set body [lindex $clause end-3]
        set matchesVar [string range [lindex $clause end-4] 1 end-1] 
        set env [lindex $clause end]

        set matches [Statements::findMatchesJoining $patterns]
        set parentStatementIds [list $collectId]
        foreach matchBindings $matches {
            lappend parentStatementIds {*}[dict get $matchBindings __matcheeIds]
        }

        set ::matchId [Matches::add $parentStatementIds]
        dict with Matches::matches $::matchId {
            set destructor [list [list lappend Evaluator::log [list Recollect $collectId]] {}]
            lappend destructors $destructor
        }

        dict set env $matchesVar $matches
        tryRunInSerializedEnvironment $body $env
    }
    proc reactToStatementAdditionThatMatchesCollect {collectId collectPattern statementId statementClause} {
        variable log
        lappend log [list Recollect $collectId]
    }

    proc lsplit {lst delimiter} {
        set lsts [list]
        set lastLst [list]
        foreach item $lst {
            if {$item eq $delimiter} {
                lappend lsts $lastLst
                set lastLst [list]
            } else { lappend lastLst $item }
        }
        lappend lsts $lastLst
        set lsts
    }
    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lrange $clause 0 4] eq "when the collected matches for"} {
            # when the collected matches for [list the time is /t/ & Omar is cool] are /matches/ { ... } with environment /__env/
            #   -> {the time is /t/} {Omar is cool}
            set patterns [lsplit [lindex $clause 5] &]
            # For each pattern, add a reaction to that pattern.
            foreach pattern $patterns {
                addReaction $pattern $id [list reactToStatementAdditionThatMatchesCollect $id $pattern]
            }

            variable log; lappend log [list Recollect $id $pattern]

        } elseif {[lindex $clause 0] eq "when"} {
            # when the time is /t/ & the fox is out { ... } with environment /__env/ -> {the time is /t/} {the fox is out}
            set patterns [lsplit [lrange $clause 1 end-4] &]

            # For each pattern, add a reaction to that pattern that,
            # on matching-statement-addition, will do a full scan for
            # the join.
            for {set i 0} {$i < [llength $patterns]} {incr i} {
                set pattern [lindex $patterns $i]
                set otherPatterns [lreplace $patterns $i $i]
                addReaction $pattern $id [list reactToStatementAdditionThatMatchesWhen $id $pattern $otherPatterns]

                if {$i == 0} {
                    # Scan the existing statement set for any already-existing
                    # matching statements.
                    set alreadyMatchingStatements [trie lookup $Statements::statementClauseToId $pattern]
                    foreach alreadyMatchingId $alreadyMatchingStatements {
                        reactToStatementAdditionThatMatchesWhen $id $pattern $otherPatterns \
                            $alreadyMatchingId [statement clause [Statements::get $alreadyMatchingId]]
                    }
                    set claimizedPattern [list /someone/ claims {*}$pattern]
                    set alreadyMatchingStatements [trie lookup $Statements::statementClauseToId $claimizedPattern]
                    foreach alreadyMatchingId $alreadyMatchingStatements {
                        reactToStatementAdditionThatMatchesWhen $id $claimizedPattern $otherPatterns \
                            $alreadyMatchingId [statement clause [Statements::get $alreadyMatchingId]]
                    }
                }
            }
        }

        # Trigger any reactions to the addition of this statement.
        variable reactionsToStatementAddition
        set reactions [trie lookup $reactionsToStatementAddition [list {*}$clause /reactingId/]]
        foreach reaction $reactions {
            {*}$reaction $id $clause
        }

        if {[lindex $clause 1] eq "claims"} {
            set unclaimizedClause [lrange $clause 2 end]
            set unclaimizedReactions [trie lookup $reactionsToStatementAddition [list {*}$unclaimizedClause /reactingId/]]
            foreach unclaimizedReaction $unclaimizedReactions {
                {*}$unclaimizedReaction $id $unclaimizedClause
            }
        }
    }
    proc reactToMatchRemoval {matchId} {
        dict with Matches::matches $matchId {
            # this match will be dead, so remove the match from the
            # other parents of the match
            foreach parentStatementId $parents {
                if {![Statements::exists $parentStatementId]} { continue }
                dict unset Statements::statements $parentStatementId children $matchId
            }

            foreach childStatementId $children {
                if {![Statements::exists $childStatementId]} { continue }
                dict unset Statements::statements $childStatementId parents $matchId
                if {[dict size [dict get $Statements::statements $childStatementId parents]] == 0} {
                    # is this child out of parent matches? => it's dead
                    reactToStatementRemoval $childStatementId
                    Statements::remove $childStatementId
                }
            }

            foreach destructor $destructors {
                tryRunInSerializedEnvironment {*}$destructor
            }
        }
    }
    proc reactToStatementRemoval {id} {
        removeAllReactions $id

        # Unset all things downstream of statement.
        set childMatchIds [statement children [Statements::get $id]]
        dict for {matchId _} $childMatchIds {
            if {![Matches::exists $matchId]} { continue } ;# if was removed earlier

            reactToMatchRemoval $matchId
            dict unset Matches::matches $matchId
        }
    }

    proc Evaluate {} {
        variable log

        # FIXME: We're only retaining this global for compatibility
        # with old metrics program.
        set ::logsize [llength $log]

        while {[llength $log]} {
            set log [lassign $log entry]

            set op [lindex $entry 0]
            # puts "============="
            # puts $entry
            if {$op eq "Assert"} {
                set clause [lindex $entry 1]
                lassign [Statements::add $clause] id isNewStatement ;# statement without parents
                if {$isNewStatement} { reactToStatementAddition $id }

            } elseif {$op eq "Retract"} {
                set pattern [lindex $entry 1]
                set ids [trie lookup $Statements::statementClauseToId $pattern]
                foreach id $ids {
                    reactToStatementRemoval $id
                    Statements::remove $id
                }

            } elseif {$op eq "Say"} {
                lassign $entry _ parentMatchId clause
                if {[Matches::exists $parentMatchId]} {
                    lassign [Statements::add $clause [dict create $parentMatchId true]] id isNewStatement
                    if {$isNewStatement} { reactToStatementAddition $id }
                }

            } elseif {$op eq "Recollect"} {
                lassign $entry _ collectId
                if {[Statements::exists $collectId]} {
                    recollect $collectId
                }

            } else {
                error "Unsupported log operation $op"
            }
        }

        if {[namespace exists Display]} {
            Display::commit ;# TODO: this is weird, not right level
        }
    }
}
# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {
    if {[lindex $args 0] eq "when" && [lindex $args end-1] ne "environment"} {
        set args [list {*}$args with environment {}]
    }
    lappend Evaluator::log [list Assert $args]
}
proc Retract {args} { lappend Evaluator::log [list Retract $args] }

# invoke from within a When context, add dependent statements
proc Say {args} {
    set Evaluator::log [linsert $Evaluator::log 0 [list Say $::matchId $args]]
}
proc Claim {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args] }
proc Wish {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args] }

proc When {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]
    uplevel [list Say when {*}$pattern $body with environment [Evaluator::serializeEnvironment]]
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
        dict with Matches::matches $::matchId {
            lappend destructors [list $body [Evaluator::serializeEnvironment]]
        }

    } else {
        error "Unknown On $event $args"
    }
}

proc After {n unit body} {
    if {$unit eq "milliseconds"} {
        set env [Evaluator::serializeEnvironment]
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
    set key [list [expr {[info exists this] ? $this : "<unknown>"}] {*}[lreplace $args end end]]
    Assert $key has program code [list Evaluator::tryRunInSerializedEnvironment $body [Evaluator::serializeEnvironment]]
    if {[dict exists ::committed $key] && [dict get ::committed $key] ne $body} {
        Retract $key has program code [dict get ::committed $key]
    }
    dict set ::committed $key $body
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

    foreach peer [namespace children Peers] {
        namespace eval $peer {
            if {[info exists shareStatements]} {
                variable prevShareStatements $shareStatements
            } else {
                variable prevShareStatements [list]
            }

            variable shareStatements [list]
            if {[llength [Statements::findMatches [list /someone/ wishes $::nodename shares all statements]]] > 0} {
                dict for {_ stmt} $Statements::statements {
                    lappend shareStatements [statement clause $stmt]
                }
            } else {
                foreach m [Statements::findMatches [list /someone/ wishes $::nodename shares statements like /pattern/]] {
                    set pattern [dict get $m pattern]
                    foreach id [trie lookup $Statements::statementClauseToId $pattern] {
                        set clause [statement clause [Statements::get $id]]
                        set match [statement unify $pattern $clause]
                        if {$match != false} {
                            lappend shareStatements $clause
                        }
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

source "lib/math.tcl"

if {[info exists ::entry]} {
    # This all only runs if we're in a primary Folk process; we don't
    # want it to run in subprocesses (which also run main.tcl).

    Assert when /peer/ shares statements /statements/ with sequence number /gen/ {
        foreach stmt $statements { Say {*}$stmt }
    }

    # this defines $this in the contained scopes
    Assert when /this/ has program code /__code/ {
        eval $__code
    }
    source "lib/process.tcl"
    source "./web.tcl"
    source $::entry
}
