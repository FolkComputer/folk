set ::statements [dict create]
set ::whens [list]

proc Claim {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone claims {*}$args] true
}
proc Wish {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone wishes {*}$args] true
}

proc When {args} {
    set clause [lreplace $args end end]
    set cb [lindex $args end]

    lappend ::whens [list $clause $cb]
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

proc frame {} {
    # empty this out. it should be except for givens (the time is t etc)
    # set ::statements [dict create]

    # TODO: implement incremental evaluation
    # there must be a function frame' that is in terms of diffs ...

    foreach when $::whens {
        set clause [lindex $when 0]
        set cb [lindex $when 1]
        # TODO: use a trie or regexes or something
        dict for {statement _} $::statements {
            set match [matches $clause $statement]
            if {$match == false} {
                set match [matches [list /someone/ claims {*}$clause] $statement]
            }
            if {$match != false} {
                dict with match $cb
            }
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
