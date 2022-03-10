set ::statements [dict create]

proc Claim {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone claims {*}$args] true
}
proc Wish {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone wishes {*}$args] true
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
        if {$match == false} {
            set match [matches [list /someone/ claims {*}$clause] $statement]
        }
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

# Wish "/dev/fb0" draws a rectangle with x 0 y
# "<window UUID>" wishes "/dev/fb0" draws a rectangle with x 0 y 0
# (I want to invoke that from a window on my laptop which has a UUID.)

When the time is /t/ {
    Claim page 3000 has width 30 height 20

    When page /pageId/ has width /width/ height /height/ {
        # issue a draw call to vkvg
    }
}

# with key1 /value1/ key2 /value2/
# With all /matches/
# To know when
