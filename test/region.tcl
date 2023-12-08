proc lequal {l1 l2} {
    foreach elem $l1 {
        if {$elem ni $l2} {
            return 0
        }
    }
    foreach elem $l2 {
        if {$elem ni $l1} {
            return 0
        }
    }
    return 1
}

proc pointsFromAscii {ascii} {
    set x 0
    set y 0
    set points [list]
    foreach line [split $ascii \n] {
        foreach char [split $line ""] {
            if {$char == "*"} {
                lappend points [list $x $y]
            }
            set x [+ $x 1]
        }
        set x 0
        set y [+ $y 1]
    }
    return $points
}

proc testCH {name expected points} {
    puts "\n$name"
    set ch [region convexHull $points]
    lassign $ch vertices edges
    puts $edges
    assert [lequal $edges $expected]
}

testCH "Empty list" \
    [list] [list]

testCH "One point" \
    [list [list 0 0]] [pointsFromAscii "*"]

testCH "Line" \
    [list [list 0 1] [list 1 0]] \
    [pointsFromAscii "*  *"]

testCH "Triangle" \
    [list [list 0 2] [list 2 1] [list 1 0]] \
    [pointsFromAscii "
        *    *

          *
    "]

testCH "Triangle with bounded point" \
    [list [list 1 3] [list 3 0] [list 0 1]] \
    [pointsFromAscii "
               *
        *     
           *

           *
    "]

testCH "Square" \
    [list [list 0 2] [list 2 3] [list 3 1] [list 1 0]] \
    [pointsFromAscii "
        *     *

        *     *
    "]

testCH "Square with bounded point" \
    [list [list 0 3] [list 3 4] [list 4 1] [list 1 0]] \
    [pointsFromAscii "
        *     *
           *
        *     *
    "]


testCH "Square with bounded point #2" \
    [list [list 1 4] [list 4 3] [list 3 0] [list 0 1]] \
    [pointsFromAscii "
                *
        *     
           *
               *
        *
    "]

testCH "Pentagon" \
    [list [list 1 3] [list 3 4] [list 4 2] [list 2 0] [list 0 1]] \
    [pointsFromAscii "
                *
        *     
                   *
          *
               *
    "]

testCH "Line with point in middle" \
    [list [list 0 2] [list 2 0]] \
    [pointsFromAscii "*       *     *"]

testCH "Line with point in middle, shuffeled" \
    [list [list 0 1] [list 1 0]] \
    [list [list 0 0] [list 0 10] [list 0 5]]

testCH "Co-linear points" \
    [list [list 0 5] [list 5 2] [list 2 0]] \
    [pointsFromAscii "
        * * *
        * *
        *
    "]
