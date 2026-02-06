# math.tcl --
#
#     This file provides global math datatypes and utilities.
#

namespace eval ::vec2 {
    proc add {a b} {
        list [+ [lindex $a 0] [lindex $b 0]] [+ [lindex $a 1] [lindex $b 1]]
    }
    proc sub {a b} {
        list [- [lindex $a 0] [lindex $b 0]] [- [lindex $a 1] [lindex $b 1]]        
    }
    proc mult {a b} {
        list [* [lindex $a 0] [lindex $b 0]] [* [lindex $a 1] [lindex $b 1]]        
    }
    proc div {a b} {
        list [/ [lindex $a 0] [lindex $b 0]] [/ [lindex $a 1] [lindex $b 1]]        
    }
    proc scale {a args} {
        if {[llength $args] == 1} {
            set sx [lindex $args 0]; set sy [lindex $args 0]
        } else {
            lassign $args sx sy
        }
        list [* [lindex $a 0] $sx] [* [lindex $a 1] $sy]
    }
    proc rotate {a theta} {
        lassign $a x y
        list [expr {$x*cos($theta) + $y*sin($theta)}] \
             [expr {-$x*sin($theta) + $y*cos($theta)}]
    }
    proc distance {a b} {
        lassign $a ax ay
        lassign $b bx by
        expr {sqrt(pow($ax-$bx, 2) + pow($ay-$by, 2))}
    }
    proc normalize {a} {
        set l2 [vec2 distance $a [list 0 0]]
        vec2 scale $a [/ 1 $l2]
    }
    proc dot {a b} {
        expr {[lindex $a 0]*[lindex $b 0] + [lindex $a 1]*[lindex $b 1]}
    }
    proc distanceToLineSegment {a v w} {
        set l2 [vec2 distance $v $w]
        if {$l2 == 0.0} {
            return [distance $a $v]
        }
        set t [max 0 [min 1 [/ [dot [sub $a $v] [sub $w $v]] $l2]]]
        set proj [add $v [scale [sub $w $v] $t]]
        vec2 distance $a $proj
    }
    proc midpoint {a b} {
        lassign $a x1 y1; lassign $b x2 y2
        list [/ [+ $x1 $x2] 2] [/ [+ $y1 $y2] 2]
    }
    namespace export *
    namespace ensemble create
}

# From tcllib ::math::geometry
# Original code found at: https://www.ecse.rpi.edu/~wrf/Research/Short_Notes/pnpoly.html
# Thanks to Christian Gollwitzer, Peter Lewerin and Eduard Zozuly
proc ::math::geometry::pointInsidePolygon {point polygon} {
    lassign $point testx testy
    foreach p $polygon {
        lassign $p x y
        lappend vertx $x
        lappend verty $y
    }
    set c 0
    set nvert [llength $vertx]
    for {set i 0 ; set j [expr {$nvert-1}]} {$i < $nvert} {set j $i ; incr i} {
        if {
            (([lindex $verty $i]>$testy) != ([lindex $verty $j]>$testy)) &&
            ($testx < ([lindex $vertx $j] - [lindex $vertx $i]) *
            ($testy - [lindex $verty $i]) /
            ([lindex $verty $j] - [lindex $verty $i]) + [lindex $vertx $i])
        } {
            set c [expr {!$c}]
        }
    }
    return $c
}

namespace eval ::math {
    proc min {args} {
        if {[llength $args] == 0} { error "min: No args" }
        set min infinity
        foreach arg $args { if {$arg < $min} { set min $arg } }
        return $min
    }
    proc max {args} {
        if {[llength $args] == 0} { error "max: No args" }
        set max -infinity
        foreach arg $args { if {$arg > $max} { set max $arg } }
        return $max
    }
    proc mean {val args} {
        set sum $val
        set N [ expr { [ llength $args ] + 1 } ]
        foreach val $args {
            set sum [ expr { $sum + $val } ]
        }
        set mean [expr { double($sum) / $N }]
    }
    proc sin {x} { expr {sin($x)} }
    proc cos {x} { expr {cos($x)} }
}
namespace import ::math::*
