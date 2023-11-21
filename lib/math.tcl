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

namespace eval ::region {
    # A region is an arbitrary oriented chunk of a plane. The
    # archetypal region is the region of a program/page, which is the
    # quadrilateral area of space that is covered by that page. A
    # region is defined by a set of vertices and a set of edges among
    # those vertices. (TODO: Allow areas to be filled/unfilled.)

    proc create {vertices edges {angle 0}} {
        list $vertices $edges $angle
    }

    proc newRegion {x y w h {angle 0}} {
	set hw [expr {$w / 2.}]
	set hh [expr {$h / 2.}]
        set vertices [list \
		     [list [expr {$x-$hw}] [expr {$y+$hh}]] \
                     [list [expr {$x+$hw}] [expr {$y+$hh}]] \
                     [list [expr {$x+$hw}] [expr {$y-$hh}]] \
                     [list [expr {$x-$hw}] [expr {$y-$hh}]]]
        set edges [list [list 0 1] [list 1 2] [list 2 3] [list 3 0]]
        region rotate [region create $vertices $edges] $angle
    }

    proc vertices {r} { lindex $r 0 }
    proc edges {r} { lindex $r 1 }
    # Angle the region is rotated above the horizontal, in radians:
    proc angle {r} {
        expr {[llength $r] >= 3 ? [lindex $r 2] : 0}
    }

    proc width {r} {
        set minXp 100000
        set maxXp -100000
        foreach v [vertices [rotate $r [* -1 [angle $r]]]] {
            lassign $v xp yp
            if {$xp < $minXp} { set minXp $xp }
            if {$xp > $maxXp} { set maxXp $xp }
        }
        expr { $maxXp - $minXp }
    }
    proc height {r} {
        set minYp 100000
        set maxYp -100000
        foreach v [vertices [rotate $r [* -1 [angle $r]]]] {
            lassign $v xp yp
            if {$yp < $minYp} { set minYp $yp }
            if {$yp > $maxYp} { set maxYp $yp }
        }
        expr { $maxYp - $minYp }
    }

    proc top {r} {
        # Returns the vec2 point at the top of the region.
        set rp [rotate $r [- [angle $r]]]
        # Reduce all edges to their midpoints
        set edgeMidpoints [lmap e [edges $rp] {
            lassign [edgeToLineSegment $rp $e] p1 p2
            vec2 midpoint $p1 $p2
        }]
        # Which edge has the topmost midpoint y-coordinate?
        set topEdgeIndex [lindex [lsort -indices -real -index 1 $edgeMidpoints] 0]
        vec2 midpoint {*}[edgeToLineSegment $r [lindex [edges $r] $topEdgeIndex]]
    }
    proc left {r} {
        # Returns the vec2 point at the left of the region.
        set rp [rotate $r [- [angle $r]]]
        # Reduce all edges to their midpoints
        set edgeMidpoints [lmap e [edges $rp] {
            lassign [edgeToLineSegment $rp $e] p1 p2
            vec2 midpoint $p1 $p2
        }]
        # Which edge has the leftmost midpoint y-coordinate?
        set leftEdgeIndex [lindex [lsort -indices -real -index 0 $edgeMidpoints] 0]
        vec2 midpoint {*}[edgeToLineSegment $r [lindex [edges $r] $leftEdgeIndex]]
    }
    proc right {r} {
        # Returns the vec2 point at the right of the region.
        set rp [rotate $r [- [angle $r]]]
        # Reduce all edges to their midpoints
        set edgeMidpoints [lmap e [edges $rp] {
            lassign [edgeToLineSegment $rp $e] p1 p2
            vec2 midpoint $p1 $p2
        }]
        # Which edge has the rightmost midpoint y-coordinate?
        set rightEdgeIndex [lindex [lsort -indices -real -index 0 $edgeMidpoints] end]
        vec2 midpoint {*}[edgeToLineSegment $r [lindex [edges $r] $rightEdgeIndex]]
    }
    proc bottom {r} {
        # Returns the vec2 point at the bottom of the region.
        set rp [rotate $r [- [angle $r]]]
        # Reduce all edges to their midpoints
        set edgeMidpoints [lmap e [edges $rp] {
            lassign [edgeToLineSegment $rp $e] p1 p2
            vec2 midpoint $p1 $p2
        }]
        # Which edge has the bottommost midpoint y-coordinate?
        set bottomEdgeIndex [lindex [lsort -indices -real -index 1 $edgeMidpoints] end]
        vec2 midpoint {*}[edgeToLineSegment $r [lindex [edges $r] $bottomEdgeIndex]]
    }
    proc bottomleft {r} {
      lindex [vertices $r] 0
    }
    proc bottomright {r} {
      lindex [vertices $r] 1
    }
    proc topright {r} {
      lindex [vertices $r] 2
    }
    proc topleft {r} {
      lindex [vertices $r] 3
    }

    proc mapVertices {varname r body} {
        lreplace $r 0 0 [uplevel [list lmap $varname [vertices $r] $body]]
    }

    proc edgeToLineSegment {r e} {
        list [lindex [vertices $r] [lindex $e 0]] [lindex [vertices $r] [lindex $e 1]]
    }
    proc distance {r1 r2} {
        set minDist 1e9
        foreach v1 [vertices $r1] e2 [edges $r2] {
            set dist [vec2 distanceToLineSegment $v1 {*}[edgeToLineSegment $r2 $e2]]
            if {$dist < $minDist} { set minDist $dist }
        }
        set minDist
    }

    proc contains {r1 p} {
        lassign $r1 vertices edges
        lassign $vertices a b c d

        set ab [vec2 sub $b $a]
        set ap [vec2 sub $p $a]
        set bc [vec2 sub $c $b]
        set bp [vec2 sub $p $b]
        set dot_abap [vec2 dot $ab $ap]
        set dot_bcbp [vec2 dot $bc $bp]

        expr {0 <= $dot_abap && $dot_abap <= [vec2 dot $ab $ab] && \
                0 <= $dot_bcbp && $dot_bcbp <= [vec2 dot $bc $bc]}
    }
    proc intersects {r1 r2} {
        # Either r1 should contain a vertex of r2 or r2 should contain a vertex of r1
        foreach v1 [vertices $r1] {
            if {[contains $r2 $v1]} { return true }
        }
        foreach v2 [vertices $r2] {
            if {[contains $r1 $v2]} { return true }
        }
        expr false
    }

   proc centroid {r1} {
        # This only works for rectangular regions
        lassign $r1 vertices edges
        lassign $vertices a b c d

        set vecsum [vec2 add [vec2 add [vec2 add $a $b] $c] $d]
        vec2 scale $vecsum 0.25
    }

    proc rotate {r angle} {
        set theta [angle $r]
        set c [centroid $r]
        set r' [mapVertices v $r {
            set v [vec2 sub $v $c]
            set v [vec2 rotate $v $angle]
            set v [vec2 add $v $c]
            set v
        }]
        lset r' 2 [+ $theta $angle]
        set r'
    }

    # Scales about the center of the region, along the x and y axes of
    # the space of the region (not the global x and y).
    proc scale {r args} {
        if {[llength $args] == 1} {
            set args [list width [lindex $args 0] height [lindex $args 0]]
        }
        set sxp 1; set syp 1
        foreach {dim value} $args {
            set theta [angle $r]
            set c [centroid $r]

            if {![regexp {([0-9\.]+)(px|%)?} $value -> value unit]} {
                error "region scale: Invalid scale value $value"
            }

            if {$dim eq "width"} {
                if {$unit eq "px"} {
                    set sxp [* $sxp [/ $value [width $r]]]
                } elseif {$unit eq "%"} {
                    set sxp [* $sxp $value 0.01]
                } elseif {$unit eq ""} {
                    set sxp [* $sxp $value]
                }
            } elseif {$dim eq "height"} {
                if {$unit eq "px"} {
                    set syp [* $syp [/ $value [height $r]]]
                } elseif {$unit eq "%"} {
                    set syp [* $syp [* $value 0.01]]
                } elseif {$unit eq ""} {
                    set syp [* $syp $value]
                }
            } else {
                error "region scale: Invalid dimension $dim"
            }
        }

        # TODO: Optimize
        set r [mapVertices v $r {
            set v [vec2 sub $v $c]
            set v [vec2 rotate $v [* -1 $theta]]
            set v [vec2 scale $v $sxp $syp]
            set v [vec2 rotate $v $theta]
            set v [vec2 add $v $c]
            set v
        }]
        set r
    }

    # Moves the region left/right/up/down along the x and y axes of
    # the space of the region (not the global x and y).
    proc move {r args} {
        foreach {direction distance} $args {
            set theta [angle $r]

            if {![regexp {([0-9\.]+)(px|%)?} $distance -> distance unit]} {
                error "region move: Invalid distance $distance"
            }
            if {$direction ne "left" && $direction ne "right" &&
                $direction ne "up" && $direction ne "down"} {
                error "region move: Invalid direction $direction"
            }

            if {$unit eq "%"} {
                set distance [* $distance 0.01]
                set unit ""
            }
            if {$unit eq ""} {
                # Convert to pixels
                if {$direction eq "left" || $direction eq "right"} {
                    set distance [expr {[width $r] * $distance}]
                } elseif {$direction eq "up" || $direction eq "down"} {
                    set distance [expr {[height $r] * $distance}]
                }
            }
            set dxp [if {$direction eq "left"} {- $distance} \
                     elseif {$direction eq "right"} {+ $distance} \
                     else {+ 0}]
            set dyp [if {$direction eq "up"} {- $distance} \
                     elseif {$direction eq "down"} {+ $distance} \
                     else {+ 0}]
            set dv [vec2 rotate [list $dxp $dyp] $theta]
            set r [mapVertices v $r {vec2 add $v $dv}]
        }
        set r
    }

    namespace export *
    namespace ensemble create
}

proc rectanglesOverlap {P1 P2 Q1 Q2 strict} {
    set b1x1 [lindex $P1 0]
    set b1y1 [lindex $P1 1]
    set b1x2 [lindex $P2 0]
    set b1y2 [lindex $P2 1]
    set b2x1 [lindex $Q1 0]
    set b2y1 [lindex $Q1 1]
    set b2x2 [lindex $Q2 0]
    set b2y2 [lindex $Q2 1]
    # ensure b1x1<=b1x2 etc.
    if {$b1x1 > $b1x2} {
	set temp $b1x1
	set b1x1 $b1x2
	set b1x2 $temp
    }
    if {$b1y1 > $b1y2} {
	set temp $b1y1
	set b1y1 $b1y2
	set b1y2 $temp
    }
    if {$b2x1 > $b2x2} {
	set temp $b2x1
	set b2x1 $b2x2
	set b2x2 $temp
    }
    if {$b2y1 > $b2y2} {
	set temp $b2y1
	set b2y1 $b2y2
	set b2y2 $temp
    }
    # Check if the boxes intersect
    # (From: Cormen, Leiserson, and Rivests' "Algorithms", page 889)
    if {$strict} {
	return [expr {($b1x2>$b2x1) && ($b2x2>$b1x1) \
		&& ($b1y2>$b2y1) && ($b2y2>$b1y1)}]
    } else {
	return [expr {($b1x2>=$b2x1) && ($b2x2>=$b1x1) \
		&& ($b1y2>=$b2y1) && ($b2y2>=$b1y1)}]
    }
}

# TODO: verticesToBbox is better name
# It only really uses the first thing in the region
proc regionToBbox {region} {
    set vertices [lindex $region 0]
    set minX 100000
    set minY 100000
    set maxX -100000
    set maxY -100000
    foreach vertex $vertices {
        set x [lindex $vertex 0]
        set y [lindex $vertex 1]
        if {$x < $minX} {set minX $x}
        if {$y < $minY} {set minY $y}
        if {$x > $maxX} {set maxX $x}
        if {$y > $maxY} {set maxY $y}
    }
    return [list $minX $minY $maxX $maxY]
}
proc boxCentroid {box} {
    # TODO: assert that it's actually a box
    lassign $box minX minY maxX maxY
    set x [expr {($minX + $maxX)/2}]
    set y [expr {($minY + $maxY)/2}]
    return [list $x $y]
}
proc boxWidth {box} {
    lassign $box minX minY maxX maxY
    return [expr {$maxX - $minX}]
}
proc boxHeight {box} {
    lassign $box minX minY maxX maxY
    return [expr {$maxY - $minY}]
}
# TODO: write in C
# TODO: triangulate the region
# TODO: average the centroids of all triangles in the region
