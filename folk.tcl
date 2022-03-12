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

# Wish "/dev/fb0" shows a rectangle with x 0 y
# "<window UUID>" wishes "/dev/fb0" shows a rectangle with x 0 y 0
# (I want to invoke that from a window on my laptop which has a UUID.)

# TODO: use Vulkan (-:
set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

set black [binary format b16 [join {00000 000000 00000} ""]]
set blue  [binary format b16 [join {11111 000000 00000} ""]]
set green [binary format b16 [join {00000 111111 00000} ""]]
set red   [binary format b16 [join {00000 000000 11111} ""]]

proc fbFillRect {fb x0 y0 x1 y1 color} {
    for {set y $y0} {$y < $y1} {incr y} {
        for {set x $x0} {$x < $x1} {incr x} {
            puts -nonewline $fb $color
        }
    }
}
proc fbFillScreen {fb color} {
    fbFillRect $fb 0 0 1920 1080 $color
}

When /someone/ wishes /device/ shows a rectangle with \
    x /x/ y /y/ width /width/ height /height/ fill /color/ {
        fbFillRect $fb $x $y [expr $x + $width] [expr $y + $height] $color
}

# with key1 /value1/ key2 /value2/
# With all /matches/
# To know when

proc step {} {
    global fb black

    # clear the screen
    fbFillScreen $fb $black

    # infinite event loop
    # event: an incoming statement bundle
    # a statement bundle includes statements and statement-retractions
    # do peers need to connect? or is it like a message thing?
    # there needs to be a persistent statement database?
    frame
    # is there an effect set that comes out of the frame?
    
    # stream effects/output statement set outward?
    # (for now, draw all the graphics requests)
}
after 0 step

vwait forever
