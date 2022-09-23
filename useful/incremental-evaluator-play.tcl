namespace eval Statements { ;# singleton Statement store
    variable statements [dict create] ;# Map<StatementId, Statement>
    variable nextStatementId 1

    proc add {clause parents} {
        variable statements
        variable nextStatementId

        set id [incr nextStatementId]
        set stmt [statement create $clause $parents]
        dict set statements $id $stmt
        return $id
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
        # TODO: multi-level matching
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
            lappend dot "$id \[label=<$label>\];"
            foreach child [statement children $stmt] {
                lappend dot "$id -> $child;"
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
    namespace export create addChild
    proc create {clause parents {children {}}} {
        return [dict create clause $clause parents $parents children $children]
    }

    namespace export clause parents children
    proc clause {stmt} { return [dict get $stmt clause] }
    proc parents {stmt} { return [dict get $stmt parents] }
    proc children {stmt} { return [dict get $stmt children] }

    namespace ensemble create
}

set ::log [list]
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

proc Claim {args} {
    upvar __matcherId matcherId
    upvar __matcheeId matcheeId
    lappend ::log [list Claim [list $matcherId $matcheeId] $args]
}

proc Step {} {
    # should this do reduction of assert/retract ?

    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lindex $clause 0] == "when"} {
            # is this a When? match it against existing statements
            # when the time is /t/ { ... } -> the time is /t/
            set unwhenizedClause [lreplace [lreplace $clause end end] 0 0]
            set matches [Statements::findMatches $unwhenizedClause]
            set body [lindex $clause end]
            foreach bindings $matches {
                dict set bindings __matcherId $id
                dict with bindings $body
            }

        } else {
            # is this a statement? match it against existing whens
            # the time is 3 -> when the time is 3 /__body/
            set whenizedClause [list when {*}$clause /__body/]
            set matches [Statements::findMatches $whenizedClause]
            foreach bindings $matches {
                dict set bindings __matcherId $id
                dict with bindings [dict get $bindings __body]
            }
        }
    }
    proc reactToStatementRemoval {id} {
        # FIXME: unset all things downstream of statement
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
            set id [Statements::add $clause [list]] ;# statement without parents
            reactToStatementAddition $id

        } elseif {$op == "Retract"} {
            set clause [lindex $entry 1]
            foreach bindings [Statements::findMatches $clause] {
                set id [dict get $bindings __matcheeId]
                Statements::remove $id
            }
            reactToStatementRemoval $id

        } elseif {$op == "Claim"} {
            set parents [lindex $entry 1]
            set clause [lindex $entry 2]
            set id [Statements::add $clause $parents]
            # list this statement as a child under each of its parents
            foreach parentId $parents {
                dict with Statements::statements $parentId {
                    lappend children $id
                }
            }
            reactToStatementAddition $id
        }
    }
}

# Single-level
# ------------

# the next 2 assertions should work in either order
Assert the time is 3
Assert when the time is /t/ {
    puts "the time is $t"
}
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
