set ::statements [dict create]

proc Claim {args} {
    dict set ::statements $args true
}

proc matches {clause statement} {
    set match [dict create]

    for {set i 0} {$i < [llength $clause]} {incr i} {
        set clauseWord [lindex $clause $i]
        set statementWord [lindex $statement $i]
        if {[string index $clauseWord 0] eq "/"} {
            set clauseVarName [string range $clauseWord 1 [expr [string length $clauseWord] - 2]]
            set clauseVarValue $statementWord
            dict set match $clauseVarName $clauseVarValue

        } elseif {$clauseWord != $statementWord} {
            return false
        }
    }
    return $match
}

proc When {args} {
    set clause [lreplace $args end end]
    set cb [lindex $args end]

    dict for {statement _} $::statements {
        set match [matches $clause $statement]
        if {$match != false} {
            dict with match $cb
        }
    }
}

Claim the fox is out
Claim the dog is out

When the /animal/ is out {
    puts "there is a $animal out there somewhere"
    Claim the $animal is around
}

When the /animal/ is around {
    puts "hello $animal"
}
