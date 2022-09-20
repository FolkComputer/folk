proc Claim {args} { dict set ::statements [list someone claims {*}$args] true }
proc Wish {args} { dict set ::statements [list someone wishes {*}$args] true }
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

set ::statements [dict create]
set ::whens [dict create]

set ::log [list]
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}
proc Step {} {
    # should this do reduction of assert/retract ?

    proc matchAgainstExistingStatements {clause} {
        # FIXME: compute coherent statement set w/ zippers
        dict for {stmt _} $statements {
            set match [matches $clause $stmt]
        }
    }

    puts ""
    puts "Step:"
    puts "-----"

    foreach delta $::log {
        lassign $delta op clause
        puts "$op: $statement"

        if {$op == "Assert"} {
            dict set ::statements $clause true

            if {[lindex $clause 0] == "when"} {
                # is this a When? match it against existing statements
                # when the time is /t/ { ... } -> the time is /t/
                set unwhenizedClause [lreplace [lreplace $clause end end] 0 0]
                matchAgainstExistingStatements $unwhenizedClause

            } else {
                # is this a statement? match it against existing whens
                # the time is 3 -> when the time is 3 /body/
                set whenizedClause [list when {*}$clause /body/]
                matchAgainstExistingStatements $whenizedClause
            }

        } elseif {$op == "Retract"} {
            dict unset ::statements $clause
            # FIXME: unset all things downstream of statement
        }
    }
    set ::log [list]
}

Assert the time is 3
Assert when the time is /t/ {
    puts "the time is $t"
}
Step ;# should output "the time is 3"


Retract the time is 3
Assert the time is 4
Step ;# should output "the time is 4"



# Assert when the time is /t/ {
#     Claim the time is definitely $t
# }
# Retract the time is 3
# Assert the time is 4

# Step

# Step

# Step

# Step {
#     When the time is /t/ {
#         Claim the time is definitely $t
#     }
# }
# print the statement set

# Retract the time is /t/
# Assert the time is 4
# Step
# print the statement set
