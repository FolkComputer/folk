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

    lappend ::whens [list $clause $cb $::currentMatchStack]
}

proc To {_know _when args} { # FIXME
    set clause [lreplace $args end end]
    set cb [lindex $args end]
}

# TODO: top/prelude/boot context ?

proc runWhen {clause cb enclosingMatchStack match} {
    set ::currentMatchStack [dict merge $enclosingMatchStack $match]
    dict with ::currentMatchStack $cb
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

proc evaluate {} {
    # TODO: implement incremental evaluation
    # there must be a function frame' that is in terms of diffs ...

    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        set when [lindex $::whens $i]
        set clause [lindex $when 0]
        set cb [lindex $when 1]
        set enclosingMatchStack [lindex $when 2]
        # TODO: use a trie or regexes or something
        dict for {statement _} $::statements {
            set match [matches $clause $statement]
            if {$match == false} {
                set match [matches [list /someone/ claims {*}$clause] $statement]
            }
            if {$match != false} {
                runWhen $clause $cb $enclosingMatchStack $match
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
    # TODO: support 'assumed'/'prelude' statements
    set ::statements [dict create]
    set ::whens [list]

    set ::currentMatchStack [dict create]

    eval $cb

    # event: an incoming statement bundle
    # a statement bundle includes statements and statement-retractions
    # do peers need to connect? or is it like a message thing?
    # there needs to be a persistent statement database?
    evaluate
    # is there an effect set that comes out of the frame?

    puts $::statements
    # stream effects/output statement set outward?
    # (for now, draw all the graphics requests)
}

# we probably don't need this
after 0 { Step {} }

# on each frame {
#     global fb black green

#     # clear the screen
#     fbFillScreen $fb $black
# }

# With all matches -> clear screen, do rendering
# or When unmatched -> clear that thing
# or just have a custom frame hook that pi.tcl can hit

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

        When /rect/ is a rectangle with x /x/ y /y/ width /width/ height /height/ {
            When /someone/ wishes $rect is highlighted /color/ {
                # it's not really correct to just stick a side-effect in the
                # When handler like this. but we did it in Realtalk, and it
                # was ok, so whatever for now
                Display::fillRect device $x $y [expr $x+$width] [expr $y+$height] $color
            }
        }
        Claim "rect1" is a rectangle with x 300 y 400 width 50 height 60
        Wish "rect1" is highlighted $Display::green

        Claim "rect2" is a rectangle with x 300 y 460 width 20 height 20
        Wish "rect2" is highlighted $Display::red

        To know when /known a/ points up at /unknown b/ { # FIXME
            When $a is a rectangle with x /ax/ y /ay/ width /awidth/ height /aheight/ {
                # TODO: we'll probably need join support
                When $b is a rectangle with x /bx/ y /by/ width /bwidth/ height /bheight/ {
                    if {$ay + $aheight < $by && $by - ($ay + $aheight) < 10} {
                        Claim $a points up at $b
                    }
                }
            }
        }
        
        When "rect2" points up at "rect1" { # FIXME
            puts "points up"
        }
    }
}

if {$tcl_platform(os) eq "Darwin"} {
    if {$tcl_version eq 8.5} {
        error "Don't use macOS system Tcl. Quitting."
    }
    source laptop.tcl
} else {
    source pi.tcl
}

vwait forever
