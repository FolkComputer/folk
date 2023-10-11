namespace eval Evaluator { source "lib/environment.tcl" }
source "lib/language.tcl"

lappend auto_path "./vendor"
package require math::linearalgebra
rename ::scale scaleTk
namespace import ::math::linearalgebra::*

proc findHomography {sideLength detection} {
    set ROWS 4
    set COLS 6

    # Camera points, from the camera image.
    fn detectionTagCorner {row col corner} {
        set id [expr {48600 + $row*$COLS + $col}]
        return [lindex [dict get [dict get $detection $id] corners] $corner]
    }
    set points [list]
    for {set row 0} {$row < $ROWS} {incr row} {
        for {set col 0} {$col < $COLS} {incr col} {
            lappend points [detectionTagCorner $row $col 0]
            lappend points [detectionTagCorner $row $col 1]
            lappend points [detectionTagCorner $row $col 2]
            lappend points [detectionTagCorner $row $col 3]
        }
    }

    # Model points, from the known geometry of the checkerboard (in
    # meters, where top-left corner of top-left AprilTag is 0, 0).
    set model [list]
    for {set row 0} {$row < $ROWS} {incr row} {
        for {set col 0} {$col < $COLS} {incr col} {
            lappend model [list [* $col $sideLength 2] \
                               [+ [* $row $sideLength 2] $sideLength]] ;# bottom-left

            lappend model [list [+ [* $col $sideLength 2] $sideLength] \
                               [+ [* $row $sideLength 2] $sideLength]] ;# bottom-right

            lappend model [list [+ [* $col $sideLength 2] $sideLength] \
                               [* $row $sideLength 2]] ;# top-right

            lappend model [list [* $col $sideLength 2] [* $row $sideLength 2]] ;# top-left
        }
    }

    set Atop [list]
    set Abottom [list]
    set btop [list]
    set bbottom [list]
    foreach imagePoint $points modelPoint $model {
        lassign $imagePoint x y
        lassign $modelPoint u v
        lappend Atop    [list $x $y 1 0  0  0 [expr {-$x*$u}] [expr {-$y*$u}]]
        lappend Abottom [list 0  0  0 $x $y 1 [expr {-$x*$v}] [expr {-$y*$v}]]
        lappend btop $u
        lappend bbottom $v
    }
    set A [list {*}$Atop {*}$Abottom]
    set b [list {*}$btop {*}$bbottom]

    lassign [leastSquaresSVD $A $b] a0 a1 a2 b0 b1 b2 c0 c1
    set H [subst {
        {$a0 $a1 $a2}
        {$b0 $b1 $b2}
        {$c0 $c1 1}
    }]
    puts "H:\n[show $H]"
    return $H
}

proc processHomography {H} {
    fn h {i j} { getelem $H [- $j 1] [- $i 1] }

    fn v {i j} {
        list \
            [* [h $i 1] [h $j 1]] \
            [+ [* [h $i 1] [h $j 2]] [* [h $i 2] [h $j 1]]] \
            [* [h $i 2] [h $j 2]] \
            [+ [* [h $i 3] [h $j 1]] [* [h $i 1] [h $j 3]]] \
            [+ [* [h $i 3] [h $j 2]] [* [h $i 2] [h $j 3]]] \
            [* [h $i 3] [h $j 3]]
    }
    # TODO: How do I check v_{ij}?

    set V [list \
               [v 1 2] \
               [sub [v 1 1] [v 2 2]]]
    return $V
}

# Draw detections:
package require Tk

proc loadDetections {name sideLength detections} {
    toplevel .$name
    puts "loadDetections $name"

    set Hs [lmap detection $detections {
        findHomography $sideLength $detection
    }]
    set Hs' {
        {
            {-6.12376214e+01  2.51224928e+03  7.06880459e+02}
            {-1.27997550e+03 -3.52652107e+02  5.34330501e+02}
            {1.35055146e+00  8.41027178e-01  1.00000000e+00}
        } {
            {-5.68840037e+01  1.72681747e+03  5.38110740e+02}
            {-1.71358380e+03 -3.21315989e+02  3.93736922e+02}
            {2.70972298e-01 -1.70467299e-01  1.00000000e+00}
        } {
            {-4.69485817e+02  2.62924837e+03  4.49978347e+02}
            {-2.01425505e+03  1.48026602e+02  4.74710935e+02}
            {-5.16972709e-02  1.42189580e+00  1.00000000e+00}
        } {
            {-1.11730862e+03  1.73279606e+03  4.80027971e+02}
            {-1.79238204e+03 -3.35970800e+02  3.04904898e+02}
            {-1.41738072e+00  2.71286865e-01  1.00000000e+00}
        }
    }

    canvas .$name.canv -width 1280 -height 720 -background white
    set detectionButtons [lmap {i detection} [lenumerate $detections] {
        button .$name.detection$i -text detection$i -command [list apply {{name detection} {
            set ROWS 4
            set COLS 6

            .$name.canv delete all
            .$name.canv create rectangle 4 4 [- 1280 2] [- 720 2] -outline blue
            dict for {id tag} $detection {
                set corners [dict get $tag corners]
                .$name.canv create line {*}[join $corners] {*}[lindex $corners 0]
            }

            fn drawDetectionTagCorner {row col corner label} {
                fn detectionTagCorner {row col corner} {
                    set id [expr {48600 + $row*$COLS + $col}]
                    return [lindex [dict get [dict get $detection $id] corners] $corner]
                }
                .$name.canv create oval \
                    {*}[detectionTagCorner $row $col $corner] \
                    {*}[add [detectionTagCorner $row $col $corner] {5 5}] \
                    -fill red
                .$name.canv create text [detectionTagCorner $row $col $corner] \
                    -text $label
            }

            drawDetectionTagCorner 0 0 3 TL
            drawDetectionTagCorner 0 [- $COLS 1] 2 TR
            drawDetectionTagCorner [- $ROWS 1] [- $COLS 1] 1 BR
            drawDetectionTagCorner [- $ROWS 1] 0 0 BL
        }} $name $detection]
    }]
    set homButtons [lmap {i H} [lenumerate $Hs] {
        button .$name.h$i -text H$i -command [list apply {{name detection H} {
            .$name.canv delete all
            .$name.canv create rectangle 4 4 [- 1280 2] [- 720 2] -outline red
            dict for {id tag} $detection {
                set corners [lmap corner [dict get $tag corners] {
                    set corner [list {*}$corner 1]
                    set corner [matmul $H $corner]
                    lassign $corner cx cy cz
                    list [* [/ $cx $cz] 1000] [* [/ $cy $cz] 1000]
                }]
                .$name.canv create line {*}[join $corners] {*}[lindex $corners 0]
            }
        }} $name [lindex $detections $i] $H]
    }]
    pack .$name.canv {*}$detectionButtons {*}$homButtons -fill both -expand true

    # Try to solve for the camera intrinsics:
    try {
        # Construct V:
        set Vtop [list]; set Vbottom [list]
        foreach H $Hs {
            lassign [processHomography $H] Vtop_ Vbottom_
            lappend Vtop $Vtop_
            lappend Vbottom $Vbottom_
        }
        set V [list {*}$Vtop {*}$Vbottom]
        assert {[shape $V] eq [list [* 2 [llength $Hs]] 6]}

        # Solve Vb = 0:
        lassign [determineSVD [matmul [transpose $V] $V]] U S V'
        set b [lindex [transpose ${V'}] [lindex [lsort -real -indices $S] 0]]
        puts "b = $b"

        # Compute camera intrinsic matrix A:
        lassign $b B11 B12 B22 B13 B23 B33
        set v0 [expr {($B12*$B13 - $B11*$B23) / ($B11*$B22 - $B12*$B12)}]
        set lambda [expr {$B33 - ($B13*$B13 + $v0*($B12*$B13 - $B11*$B23))/$B11}]
        set alpha [expr {sqrt($lambda/$B11)}]
        set beta [expr {sqrt($lambda*$B11/($B11*$B22 - $B12*$B12))}]
        set gamma [expr {-$B12*$alpha*$alpha*$beta/$lambda}]
        set u0 [expr {$gamma*$v0/$beta - $B13*$alpha*$alpha/$lambda}]

        foreach var {v0 lambda alpha beta gamma u0} {
            puts "$var = [set $var]"
        }
    } on error e {
        puts stderr $::errorInfo
    }
}

set loadButtons [list]
foreach path [glob "$::env(HOME)/aux/folk-calibrate-detections/*.tcl"] {
    set name [file rootname [file tail $path]]

    lappend loadButtons [button .load-$name -text $name -command [list apply {{path name} {
        source $path
        loadDetections $name $sideLength $detections
    }} $path $name]]
}
pack {*}$loadButtons -fill both -expand true

vwait forever
