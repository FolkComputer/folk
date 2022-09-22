set ::statements [dict create]

set ::log [list]
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

# FIXME: store the current pointer to the current when so we can stick a destructor here
proc Claim {args} {lappend ::log [list Claim $args]}
proc When {args} {
    set clause [lreplace $args end end]
    set cb [lindex $args end]
    set locals [uplevel 1 { # get local variables & serialize them (to fake lexical scope)
        set localNames [info locals]
        set locals [dict create]
        foreach localName $localNames { dict set locals $localName [set $localName] }
        set locals
    }]
    lappend ::whens [list $clause $cb [dict merge $::currentMatchStack $locals]]
}

proc matches {clause statement} {
    set match [dict create]
    for {set i 0} {$i < [llength $clause]} {incr i} {
        set clauseWord [lindex $clause $i]
        set statementWord [lindex $statement $i]
        if {[regexp {^/([^/]+)/$} $clauseWord -> clauseVarName]} {
            dict set match $clauseVarName $statementWord
        } elseif {$clauseWord != $statementWord} {
            return false
        }
    }
    return $match
}
proc runWhen {clause cb enclosingMatchStack match} {
    set ::currentMatchStack [dict merge $enclosingMatchStack $match]
    dict with ::currentMatchStack $cb
}
proc evaluate {} {
    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        lassign [lindex $::whens $i] clause cb enclosingMatchStack
        dict for {stmt _} $::statements {
            set match [matches $clause $stmt]
            if {$match == false} { set match [matches [list /someone/ claims {*}$clause] $stmt] }

            if {$match != false} { runWhen $clause $cb $enclosingMatchStack $match }
        }
    }
}
proc Step {cb} {
    # clear the statement set
    set ::statements [dict create]
    set ::whens [list]
    set ::currentMatchStack [dict create]
    uplevel 1 $cb ;# run the body code

    while 1 {
        set prevStatements $::statements
        evaluate
        if {$::statements eq $prevStatements} break ;# fixpoint
    }
}

proc Step {} {
    # should this do reduction of assert/retract ?

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
        # Returns a list of bindings like {{name Bob age 27} {name Omar age 28}}
        # In each binding, also attach a statement zipper.
        # TODO: multi-level matching
        # TODO: efficient matching
        set matches [list]
        dict for {stmt _} $::statements {
            set match [unify $pattern $stmt]
            if {$match != false} {
                # TODO: store a set including {pattern, stmt} in match so that
                # when match is evaluated for when-body, it can add itself
                # as a child of pattern and of stmt
                dict set match __parents [list $pattern $stmt]
                lappend matches $match
            }
        }
        return $matches
    }

    puts ""
    puts "Step:"
    puts "-----"

    foreach delta $::log {
        lassign $delta op clause
        puts "$op: $clause"

        if {$op == "Assert"} {
            dict set ::statements $clause true

            if {[lindex $clause 0] == "when"} {
                # is this a When? match it against existing statements
                # when the time is /t/ { ... } -> the time is /t/
                set unwhenizedClause [lreplace [lreplace $clause end end] 0 0]
                set matches [findMatches $unwhenizedClause]
                set body [lindex $clause end]
                foreach bindings $matches {
                    dict with bindings $body
                }

            } else {
                # is this a statement? match it against existing whens
                # the time is 3 -> when the time is 3 /__body/
                set whenizedClause [list when {*}$clause /__body/]
                set matches [findMatches $whenizedClause]
                foreach bindings $matches {
                    dict with bindings [dict get $bindings __body]
                }
            }

        } elseif {$op == "Retract"} {
            dict for {stmt _} $::statements {
                set match [unify $clause $stmt]
                if {$match != false} {
                    dict unset ::statements $stmt
                }
            }
            # FIXME: unset all things downstream of statement
        }
    }
    set ::log [list]
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
puts "statements: {$::statements}" ;# should be empty set

# Multi-level
# -----------

Assert when the time is /t/ {
    puts "parents: $__parents"
    Claim the time is definitely $t
}
Assert when the time is definitely /ti/ {
    puts "i'm sure the time is $ti"
}
Assert the time is 6
Step ;# FIXME: should output "i'm sure the time is 6"
puts "statements: {$::statements}"
