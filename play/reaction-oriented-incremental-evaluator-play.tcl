source "lib/c.tcl"
source "lib/trie.tcl"
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    rename add add_; rename addWithVar add
    rename remove remove_; rename removeWithVar remove
    namespace ensemble create
}

namespace eval match { ;# match record type
    namespace ensemble create

    namespace export create
    proc create {{parents {}}} {
        dict create \
            parents $parents \
            children [list] \
            destructor {}
    }
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
    proc exists {id} { variable statements; dict exists $statements $id }
    proc get {id} { variable statements; dict get $statements $id }
}

namespace eval Evaluator {
    variable log [list]

    # invoke at top level, add/remove independent 'axioms' for the system
    proc Assert {args} { variable log; lappend log [list Assert $args] }
    proc Retract {args} { variable log; lappend log [list Retract $args] }

    # Trie<StatementPattern, Dict<StatementId, Reaction>>
    variable statementPatternToReactions [trie create]

    # When reactTo is called, it scans the existing statement set for
    # anything that already matches the pattern. Then it keeps
    # watching afterward as new statements come in that match the
    # pattern.
    #
    # A reaction is runnable script that gets passed the reactingId
    # and the ID of the matching statement.
    proc reactTo {pattern reactingId reaction} {
        # Scan the existing statement set for any already-existing
        # matching statements.
        set alreadyMatchingStatements [trie lookup $Statements::statementClauseToId $pattern]
        foreach id $alreadyMatchingStatements {
            {*}$reaction $reactingId $id
        }

        # Store this pattern and reaction so it can be called when a
        # new matching statement is added later.
        variable statementPatternToReactions
        set reactions [trie lookup $statementPatternToReactions $pattern]
        if {[llength $reactions] > 1} { error "Statement pattern is fan-out" }
        if {[llength $reactions] == 1} { set reactions [lindex $reactions 0] }
        if {[llength $reactions] == 0} { set reactions [dict create] }
        dict set reactions $reactingId $reaction
        trie add statementPatternToReactions $pattern $reactions
    }
    proc reactToStatementAdditionThatMatchesWhen {whenId statementId} {
        set when [Statements::get $whenId]
        set stmt [Statements::get $statementId]

        set bindings [statement unify \
                          [lrange [statement clause $when] 1 end-1] \
                          [statement clause $stmt]]

        set body [lindex [statement clause $when] end]
        dict with bindings $body
    }
    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lindex $clause 0] eq "when"} {
            # when the time is /t/ { ... } -> the time is /t/
            set pattern [lrange $clause 1 end-1]
            reactTo $pattern $id reactToStatementAdditionThatMatchesWhen
        }

        # Trigger any prior reactions.
        variable statementPatternToReactions
        set reactionses [trie lookup $statementPatternToReactions $clause]
        foreach reactions $reactionses {
            dict for {reactingId reaction} $reactions {
                {*}$reaction $reactingId $id
            }
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
            }
        }
    }
}

Evaluator::Assert the time is 4
Evaluator::Assert when the time is /t/ { puts "the time is $t" }
Evaluator::Assert when the time is /t/ { puts "also!!! the time is $t" }
Evaluator::Assert the time is 5
Evaluator::Evaluate

# set t [trie create]
# trie add t [list hello there] 1
# trie add t [list hello there] 2
# exec dot -Tpdf >trie.pdf <<[trie dot $t]
# puts [trie lookup $t [list hello there]]
