# a When Trace has
# - childWhenTraces
# - statements

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

# TODO: top/prelude/boot context ?

proc runWhen {clause cb match} {
    dict with match $cb
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

    # TODO: implement incremental evaluation
    # there must be a function frame' that is in terms of diffs ...

    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        set when [lindex $::whens $i]
        set clause [lindex $when 0]
        set cb [lindex $when 1]
        # TODO: use a trie or regexes or something
        dict for {statement _} $::statements {
            set match [matches $clause $statement]
            if {$match == false} {
                set match [matches [list /someone/ claims {*}$clause] $statement]
            }
            if {$match != false} {
                runWhen $clause $cb $match
            }
        }
    }
}

# we want to be able to asynchronously receive statements
# we want to be able to asynchronously share statements(?)
proc accept {chan addr port} {
    puts $chan $::statements
    close $chan
}
socket -server accept 4273

# with key1 /value1/ key2 /value2/
# With all /matches/
# To know when

proc Step {cb} {
    # clear the statement set
    set ::statements [dict create]
    set ::whens [list]

    eval $cb

    # infinite event loop
    # event: an incoming statement bundle
    # a statement bundle includes statements and statement-retractions
    # do peers need to connect? or is it like a message thing?
    # there needs to be a persistent statement database?
    frame
    # is there an effect set that comes out of the frame?

    puts $::statements
    # stream effects/output statement set outward?
    # (for now, draw all the graphics requests)
}
after 0 { Step {} }

# on each frame {
#     global fb black green

#     # clear the screen
#     fbFillScreen $fb $black
# }

# With all matches -> clear screen, do rendering
# or When unmatched -> clear that thing

after 200 {
    Step {
        puts Step1
        Claim the fox is out
        Claim the dog is out
        When the /animal/ is out {
            When the /animal/ is around {
                puts "the $animal is around"
            }
            puts "there is a $animal out there somewhere"
            Claim the $animal is around
        }
    }
}

after 400 {
    Step {
        puts Step2
        Wish rectangle orange
    }
}

if {$tcl_platform(os) eq "Darwin"} {
    if {$tcl_version eq 8.5} {
        error "Don't use system Tcl. Quitting."
    }
    source laptop.tcl
} else {
    source pi.tcl
}

vwait forever
