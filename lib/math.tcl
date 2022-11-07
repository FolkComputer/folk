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
