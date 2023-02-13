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
        # isZombie = false
        dict create \
            clause $clause \
            parents $parents \
            children $children \
            isZombie false
    }

    namespace export clause parents children isZombie
    proc clause {stmt} { dict get $stmt clause }
    proc parents {stmt} { dict get $stmt parents }
    proc children {stmt} { dict get $stmt children }
    proc isZombie {stmt} { dict get $stmt isZombie }

    namespace export unify
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
        dict set matches $matchId [match create]

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
            dict with statements $id {
                dict for {parentMatchId _} $addingParents {
                    dict set parents $parentMatchId true
                }
            }
        }

        # Add this statement as a child to all the parent matches
        # that were passed in.
        dict for {parentMatchId _} $parents {
            if {$parentMatchId eq {}} { continue }
            dict with Matches::matches $parentMatchId {
                lappend children $id
            }
        }

        list $id $isNewStatement
    }
    proc markZombie {id} {
        variable statements
        dict set statements $id isZombie true
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
        # {{name Bob age 27 __matcheeId 6} {name Omar age 28 __matcheeId 7}}

        set matches [list]
        foreach id [trie lookup $statementClauseToId $pattern] {
            set stmt [get $id]
            if {[statement isZombie $stmt]} { continue }

            set match [statement unify $pattern [statement clause $stmt]]
            if {$match != false} {
                dict set match __matcheeId $id
                lappend matches $match
            }
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
}

namespace eval Evaluator {
    variable log [list]

    # Trie<StatementPattern, Dict<StatementId, Reaction>>
    variable statementPatternToReactions [trie create]
    proc addReaction {pattern reactingId reaction} {
        variable statementPatternToReactions
        set reactionses [trie lookup $statementPatternToReactions $pattern]
        if {[llength $reactionses] > 1} { error "Statement pattern is fan-out" }
        if {[llength $reactionses] == 1} { set reactions [lindex $reactionses 0] }
        if {[llength $reactionses] == 0} { set reactions [dict create] }
        dict set reactions $reactingId $reaction
        trie add statementPatternToReactions $pattern $reactions
    }
    proc removeReaction {pattern reactingId} {
        variable statementPatternToReactions
        set reactionses [trie lookup $statementPatternToReactions $pattern]
        if {[llength $reactionses] != 1} { error "Statement pattern is fan-out or zero" }
        set reactions [lindex $reactionses 0]
        dict unset reactions $reactingId
        if {[dict size $reactions] == 0} {
            trie remove statementPatternToReactions $pattern
        } else {
            trie add statementPatternToReactions $pattern $reactions
        }
    }

    # When reactTo is called, it scans the existing statement set for
    # anything that already matches the pattern. Then it keeps
    # watching afterward as new statements come in that match the
    # pattern.
    #
    # A reaction is a runnable script that gets passed the reactingId
    # and the ID of the matching statement.
    proc reactTo {pattern reactingId reaction} {
        # Scan the existing statement set for any already-existing
        # matching statements.
        set alreadyMatchingStatements [trie lookup $Statements::statementClauseToId $pattern]
        foreach id $alreadyMatchingStatements {
            {*}$reaction $id
        }

        # Store this pattern and reaction so it can be called when a
        # new matching statement is added later.
        addReaction $pattern $reactingId $reaction
    }
    proc reactToStatementAdditionThatMatchesWhen {whenId whenPattern statementId} {
        if {![Statements::exists $whenId]} {
            variable statementPatternToReactions
            removeReaction $whenPattern $whenId
            return
        }
        set when [Statements::get $whenId]
        set stmt [Statements::get $statementId]

        set bindings [statement unify \
                          $whenPattern \
                          [statement clause $stmt]]
        if {$bindings ne false} {
            set ::matchId [Matches::add [list $whenId $statementId]]
            set body [lindex [statement clause $when] end-3]
            set env [lindex [statement clause $when] end]
            set env [dict merge $env $bindings]
            runInSerializedEnvironment $body $env
        }
    }
    proc recollect {collectId collectPattern} {
        # Called when a statement that someone is collecting has been
        # added or removed.

        set collect [Statements::get $collectId]
        set children [statement children $collect]
        if {[dict size $children] > 1} {
            exec dot -Tpdf >preerr.pdf <<[Statements::dot]
            error "Collect $collectId has more than 1 match: {$children}"
        } elseif {[dict size $children] == 1} {
            # Delete the existing match child immediately.
            set childMatchId [lindex [dict keys $children] 0]
            # Delete the first destructor (which does a recollect) before doing the removal.
            dict set Matches::matches $childMatchId destructors [lreplace [dict get $Matches::matches $childMatchId destructors] 0 0]
            reactToMatchRemoval $childMatchId
            dict set Statements::statements $collectId children [dict create]
        }

        set body [lindex [statement clause $collect] end-3]
        set matchesVar [string range [lindex [statement clause $collect] end-4] 1 end-1] 
        set env [lindex [statement clause $collect] end]

        set matches [Statements::findMatches $collectPattern]
        set ::matchId [Matches::add [list $collectId {*}[lmap m $matches {dict get $m __matcheeId}]]]
        dict with Matches::matches $::matchId {
            lappend destructors [list [list Evaluator::recollect $collectId $collectPattern] {}]
        }

        dict set env $matchesVar $matches
        runInSerializedEnvironment $body $env
    }
    proc reactToStatementAdditionThatMatchesCollect {collectId collectPattern statementId} {
        if {![Statements::exists $collectId]} {
            variable statementPatternToReactions
            removeReaction $collectPattern $collectId
            return
        }
        recollect $collectId $collectPattern
    }
    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lrange $clause 0 4] eq "when the collected matches for"} {
            # when the collected matches for [list the time is /t/] are /matches/ { ... } with environment /__env/ -> the time is /t/
            set pattern [lindex $clause 5]
            reactTo $pattern $id [list reactToStatementAdditionThatMatchesCollect $id $pattern]

            set claimizedPattern [list /someone/ claims {*}$pattern]
            reactTo $claimizedPattern $id [list reactToStatementAdditionThatMatchesCollect $id $claimizedPattern]

        } elseif {[lindex $clause 0] eq "when"} {
            # when the time is /t/ { ... } with environment /__env/ -> the time is /t/
            set pattern [lrange $clause 1 end-4]
            reactTo $pattern $id [list reactToStatementAdditionThatMatchesWhen $id $pattern]

            # when the time is /t/ { ... } with environment /__env/ -> /someone/ claims the time is /t/
            set claimizedPattern [list /someone/ claims {*}$pattern]
            reactTo $claimizedPattern $id [list reactToStatementAdditionThatMatchesWhen $id $claimizedPattern]
        }

        # Trigger any prior reactions.
        variable statementPatternToReactions
        set reactionses [trie lookup $statementPatternToReactions $clause]
        foreach reactions $reactionses {
            dict for {reactingId reaction} $reactions {
                {*}$reaction $id
            }
        }
    }
    proc reactToMatchRemoval {matchId} {
        dict with Matches::matches $matchId {
            # this match will be dead, so remove the match from the
            # other parents of the match
            foreach parentStatementId $parents {
                if {![Statements::exists $parentStatementId]} { continue }
                dict with Statements::statements $parentStatementId {
                    dict unset children $matchId
                }
            }

            foreach childStatementId $children {
                if {![Statements::exists $childStatementId]} { continue }
                dict with Statements::statements $childStatementId {
                    dict unset parents $matchId

                    # is this child out of parent matches? => it's dead
                    if {[dict size $parents] == 0} {
                        reactToStatementRemoval $childStatementId
                        Statements::remove $childStatementId
                        set children [lmap cid $children {expr {$cid == $childStatementId ? [continue] : $cid }}]
                    }
                }
            }

            foreach destructor $destructors {
                runInSerializedEnvironment {*}$destructor
            }
        }
    }
    proc reactToStatementRemoval {id} {
        # unset all things downstream of statement
        Statements::markZombie $id
        set childMatchIds [statement children [Statements::get $id]]
        dict for {matchId _} $childMatchIds {
            if {![Matches::exists $matchId]} { continue } ;# if was removed earlier

            reactToMatchRemoval $matchId
            dict unset Matches::matches $matchId
        }
    }

    proc Evaluate {} {
        variable log
        while {[llength $log]} {
            set log [lassign $log entry]

            set op [lindex $entry 0]
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
                lassign [Statements::add $clause [dict create $parentMatchId true]] id isNewStatement
                if {$isNewStatement} { reactToStatementAddition $id }

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
source "lib/environment.tcl"
proc When {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]
    uplevel [list Say when {*}$pattern $body with environment [serializeEnvironment]]
}
proc On {event args} {
    if {$event eq "process"} {
        lassign $args name body
        uplevel [list On-process $name $body]

    } elseif {$event eq "unmatch"} {
        set body [lindex $args 0]
        dict with Matches::matches $::matchId {
            lappend destructors [list $body [serializeEnvironment]]
        }
    }
}

proc StepImpl {} { Evaluator::Evaluate }
