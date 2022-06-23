package require math::linearalgebra

set points {
    {527 357 1519 1423}
    {560 367 1663 1456}
    {425 289 1103 1151}
    {458 296 1232 1168}
}
for {set i 0} {$i < [llength $points]} {incr i} {
    lassign [lindex $points $i] x$i y$i u$i v$i
}

set A [subst {
    {$x0 $y0 1 0   0   0 [expr -$x0*$u0] [expr -$y0*$u0]}
    {$x1 $y1 1 0   0   0 [expr -$x1*$u1] [expr -$y1*$u1]}
    {$x2 $y2 1 0   0   0 [expr -$x2*$u2] [expr -$y2*$u2]}
    {$x3 $y3 1 0   0   0 [expr -$x3*$u3] [expr -$y3*$u3]}
    {0   0   0 $x0 $y0 1 [expr -$x0*$v0] [expr -$y0*$v0]}
    {0   0   0 $x1 $y1 1 [expr -$x1*$v1] [expr -$y1*$v1]}
    {0   0   0 $x2 $y2 1 [expr -$x2*$v2] [expr -$y2*$v2]}
    {0   0   0 $x3 $y3 1 [expr -$x3*$v3] [expr -$y3*$v3]}
}]

set b [list $u0 $u1 $u2 $u3 $v0 $v1 $v2 $v3]

puts [math::linearalgebra::show $A]
puts [math::linearalgebra::show $b]

puts [math::linearalgebra::solveGauss $A $b]
