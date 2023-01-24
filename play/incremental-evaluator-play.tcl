namespace eval Statements { ;# singleton Statement store
    variable statements [dict create] ;# Map<StatementId, Statement>
    variable nextStatementId 1
    proc reset {} {
        variable statements
        variable nextStatementId
        set statements [dict create]
        set nextStatementId 1
    }

    proc add {clause {parents {}}} {
        # empty set of parents = an assertion
        # returns {statement-id set-of-parents-id}

        variable statements
        variable nextStatementId

        # is this clause already present in the existing statement set?
        set matches [findMatches $clause]
        if {[llength $matches] == 1} {
            set id [dict get [lindex $matches 0] __matcheeId]
            dict with statements $id {
                set newSetOfParentsId [expr {[lindex $setsOfParents end-1] + 1}]
                dict set setsOfParents $newSetOfParentsId $parents
                return [list $id $newSetOfParentsId]
            }

        } elseif {[llength $matches] == 0} {
            set id [incr nextStatementId]
            set stmt [statement create $clause [dict create 0 $parents]]
            dict set statements $id $stmt
            return [list $id 0]

        } else {
            # there are somehow multiple existing matches. this seems bad
            puts BAD
        }
    }
    proc get {id} {
        variable statements
        return [dict get $statements $id]
    }
    proc remove {id} {
        variable statements
        dict unset statements $id
    }
    
    proc unify {a b} {
        if {[llength $a] != [llength $b]} { return false }

        set match [dict create]
        for {set i 0} {$i < [llength $a]} {incr i} {
            set aWord [lindex $a $i]
            set bWord [lindex $b $i]
            if {[regexp {^/([^/]+)/$} $aWord -> aVarName]} {
                dict set match $aVarName $bWord
            } elseif {[regexp {^/([^/]+)/$} $bWord -> bVarName]} {
                dict set match $bVarName $aWord
            } elseif {$aWord != $bWord} {
                return false
            }
        }
        return $match
    }
    proc findMatches {pattern} {
        variable statements
        # Returns a list of bindings like {{name Bob age 27 __matcheeId 6} {name Omar age 28 __matcheeId 7}}
        # TODO: efficient matching
        set matches [list]
        dict for {id stmt} $statements {
            set match [unify $pattern [statement clause $stmt]]
            if {$match != false} {
                dict set match __matcheeId $id
                lappend matches $match
            }
        }
        return $matches
    }

    proc graph {} {
        variable statements
        set dot [list]
        dict for {id stmt} $statements {
            set label [string map {"\n" "<br/>"} [statement clause $stmt]]
            lappend dot "$id \[label=<$id: $label>\];"

            dict for {setOfParentsId parents} [statement setsOfParents $stmt] {
                lappend dot "\"$id $setOfParentsId\" \[label=\"$id#$setOfParentsId: $parents\"\];"
                lappend dot "\"$id $setOfParentsId\" -> $id;"
            }
            dict for {child _} [statement children $stmt] {
                lappend dot "$id -> \"$child\";"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
    }
    proc showGraph {} {
        set fp [open "incremental-evaluator-play-statements.dot" "w"]
        puts -nonewline $fp [graph]
        close $fp
        exec dot -Tpdf incremental-evaluator-play-statements.dot > incremental-evaluator-play-statements.pdf
    }
    proc openGraph {} {
        exec open incremental-evaluator-play-statements.pdf
    }
}

namespace eval statement { ;# statement record type
    namespace export create
    proc create {clause {setsOfParents {}} {children {}}} {
        # clause = [list the fox is out]
        # parents = [dict create 0 [list 2 7] 1 [list 8 5]]
        # children = [dict create [list 9 0] true]
        return [dict create \
                    clause $clause \
                    setsOfParents $setsOfParents \
                    children $children]
    }

    namespace export clause setsOfParents children
    proc clause {stmt} { return [dict get $stmt clause] }
    proc setsOfParents {stmt} { return [dict get $stmt setsOfParents] }
    proc children {stmt} { return [dict get $stmt children] }

    namespace ensemble create
}

set ::log [list]

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

# invoke from within a When context, add dependent statements
proc Say {args} {
    upvar __matcherId matcherId
    upvar __matcheeId matcheeId
    set ::log [linsert $::log 0 [list Say [list $matcherId $matcheeId] $args]]
}
proc Claim {args} { uplevel [list Say someone claims {*}$args] }
proc Wish {args} { uplevel [list Say someone wishes {*}$args] }
proc When {args} {
    set env [uplevel {
        set ___env $__env ;# inherit existing environment

        # get local variables and serialize them
        # (to fake lexical scope)
        foreach localName [info locals] {
            if {![string match "__*" $localName]} {
                dict set ___env $localName [set $localName]
            }
        }
        set ___env
    }]
    uplevel [list Say when {*}$args with environment $env]
}

proc Step {} {
    # should this do reduction of assert/retract ?

    proc runWhen {__env __body} {
        dict with __env $__body
    }

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
                set __env [dict merge \
                               $env \
                               $match \
                               [dict create __matcherId $id]]
                runWhen $__env $body
            }

        } else {
            # is this a statement? match it against existing whens
            # the time is 3 -> when the time is 3 /__body/ with environment /__env/
            proc whenize {clause} { return [list when {*}$clause /__body/ with environment /__env/] }
            set matches [Statements::findMatches [whenize $clause]]
            if {[Statements::unify [lrange $clause 0 1] [list /someone/ claims]] != false} {
                # Omar claims the time is 3 -> when the time is 3 /__body/ with environment /__env/
                lappend matches {*}[Statements::findMatches [whenize [lrange $clause 2 end]]]
            }
            foreach match $matches {
                set __env [dict merge \
                               [dict get $match __env] \
                               $match \
                               [dict create __matcherId $id]]
                runWhen $__env [dict get $match __body]
            }
        }
    }
    proc reactToStatementRemoval {id} {
        # unset all things downstream of statement
        set children [statement children [Statements::get $id]]
        dict for {child _} $children {
            lassign $child childId childSetOfParentsId
            set childSetsOfParents [statement setsOfParents [Statements::get $childId]]
            set parentsInSameSet [dict get $childSetsOfParents $childSetOfParentsId]

            # this set of parents will be dead, so remove the set from
            # the other parents in the set
            foreach parentId $parentsInSameSet {
                dict with Statements::statements $parentId {
                    dict unset children $child
                }
            }

            dict with Statements::statements $childId {
                dict unset setsOfParents $childSetOfParentsId

                # is this child out of parent sets? => it's dead
                if {[dict size $setsOfParents] == 0} {
                    reactToStatementRemoval $childId
                    Statements::remove $childId
                }
            }
        }
    }

    puts ""
    puts "Step:"
    puts "-----"

    while {[llength $::log]} {
        # TODO: make this log-shift more efficient?
        set entry [lindex $::log 0]
        set ::log [lreplace $::log 0 0]

        set op [lindex $entry 0]
        puts "$op: $entry"
        if {$op == "Assert"} {
            set clause [lindex $entry 1]
            # insert empty environment if not present
            if {[lindex $clause 0] == "when" && [lrange $clause end-2 end-1] != "with environment"} {
                set clause [list {*}$clause with environment {}]
            }
            lassign [Statements::add $clause] id ;# statement without parents
            reactToStatementAddition $id

        } elseif {$op == "Retract"} {
            set clause [lindex $entry 1]
            foreach bindings [Statements::findMatches $clause] {
                set id [dict get $bindings __matcheeId]
                reactToStatementRemoval $id
                Statements::remove $id
            }

        } elseif {$op == "Say"} {
            set parents [lindex $entry 1]
            set clause [lindex $entry 2]
            lassign [Statements::add $clause $parents] id setOfParentsId
            # list this statement as a child under each of its parents
            foreach parentId $parents {
                dict with Statements::statements $parentId {
                    dict set children [list $id $setOfParentsId] true
                }
            }
            reactToStatementAddition $id
        }
    }
}

# Single-level
# ------------

# the next 2 assertions should work in either order
Assert when the time is /t/ {
    puts "the time is $t"
}
Assert the time is 3
Step ;# should output "the time is 3"

Retract the time is 3
Assert the time is 4
Step ;# should output "the time is 4"

Retract when the time is /t/ /anything/
Retract the time is 4
Assert the time is 5
Step ;# should output nothing

Retract the time is /t/
Step ;# should output nothing
puts "statements: {$Statements::statements}" ;# should be empty set

# Multi-level
# -----------

Assert when the time is /t/ {
    Claim the time is definitely $t
}
Assert when the time is definitely /ti/ {
    puts "i'm sure the time is $ti"
}
Assert the time is 6
Step ;# should output "i'm sure the time is 6"
puts "log: {$::log}" ;# should be empty
# puts "statements: {$Statements::statements}"

proc A {args} {
    Assert {*}$args
    Step
    Statements::showGraph
}
proc R {args} {
    Retract {*}$args
    Step
    Statements::showGraph
}

Assert when the time is definitely /t/ {
    Claim the time is really definitely $t
}
Retract the time is 6
Assert the time is 10
Step

# Multi-parent-set statmeents
# ---------------------------
Statements::reset
Assert when the fox is out {
    Claim the fox has been seen to be out
}
Assert when the time is 6 {
    Claim the fox has been seen to be out
}
Assert the fox is out
Assert the time is 6
Step

# Whens
# -----
Statements::reset
Assert when you are ready {
    When the fox is out {
        puts "the fox is out"
    }
}
Assert the fox is out
Step

Assert you are ready
Step

# Lexical scope
# -------------
Statements::reset
Assert when the time is /t/ {
    set excl "!"
    When you are ready {
        puts "the time is $t $excl"
    }
}
Assert the time is 6
Assert you are ready
Step
