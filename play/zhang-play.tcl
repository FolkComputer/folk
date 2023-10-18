namespace eval Evaluator { source "lib/environment.tcl" }
source "lib/language.tcl"

lappend auto_path "./vendor"
package require math::linearalgebra
rename ::scale scaleTk
namespace import ::math::linearalgebra::*

proc findHomography {modelPoints imagePoints} {
    set ROWS 4
    set COLS 6

    set A [list]
    set b [list]
    foreach imagePoint $imagePoints modelPoint $modelPoints {
        lassign $imagePoint u v
        lassign $modelPoint x y
        lappend A [list $x $y 1 0  0  0 [expr {-$x*$u}] [expr {-$y*$u}]]
        lappend A [list 0  0  0 $x $y 1 [expr {-$x*$v}] [expr {-$y*$v}]]
        lappend b $u $v
    }

    lassign [leastSquaresSVD $A $b] a0 a1 a2 b0 b1 b2 c0 c1
    set H [subst {
        {$a0 $a1 $a2}
        {$b0 $b1 $b2}
        {$c0 $c1 1}
    }]

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
    set ROWS 4
    set COLS 6

    toplevel .$name
    puts "loadDetections $name"

    # Model points, from the known geometry of the checkerboard (in
    # meters, where top-left corner of top-left AprilTag is 0, 0).
    set modelPoints [list]
    for {set row 0} {$row < $ROWS} {incr row} {
        for {set col 0} {$col < $COLS} {incr col} {
            lappend modelPoints \
                [list [* $col $sideLength 2] \
                     [+ [* $row $sideLength 2] $sideLength]] ;# bottom-left
            
            lappend modelPoints \
                [list [+ [* $col $sideLength 2] $sideLength] \
                     [+ [* $row $sideLength 2] $sideLength]] ;# bottom-right

            lappend modelPoints \
                [list [+ [* $col $sideLength 2] $sideLength] \
                     [* $row $sideLength 2]] ;# top-right

            lappend modelPoints \
                [list [* $col $sideLength 2] [* $row $sideLength 2]] ;# top-left
        }
    }

    set imagePointsForDetection [list]
    proc detectionTagCorner {detection row col corner} {
        upvar COLS COLS
        set id [expr {48600 + $row*$COLS + $col}]
        return [lindex [dict get [dict get $detection $id] corners] $corner]
    }
    foreach detection $detections {
        # Camera points, from the camera image.
        set imagePoints [list]
        for {set row 0} {$row < $ROWS} {incr row} {
            for {set col 0} {$col < $COLS} {incr col} {
                lappend imagePoints [detectionTagCorner $detection $row $col 0]
                lappend imagePoints [detectionTagCorner $detection $row $col 1]
                lappend imagePoints [detectionTagCorner $detection $row $col 2]
                lappend imagePoints [detectionTagCorner $detection $row $col 3]
            }
        }
        lappend imagePointsForDetection $imagePoints
    }

    set Hs [lmap imagePoints $imagePointsForDetection {
        findHomography $modelPoints $imagePoints
    }]

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
                .$name.canv create oval \
                    {*}[detectionTagCorner $detection $row $col $corner] \
                    {*}[add [detectionTagCorner $detection $row $col $corner] {5 5}] \
                    -fill red
                .$name.canv create text [detectionTagCorner $detection $row $col $corner] \
                    -text $label
            }

            drawDetectionTagCorner 0 0 3 TL
            drawDetectionTagCorner 0 [- $COLS 1] 2 TR
            drawDetectionTagCorner [- $ROWS 1] [- $COLS 1] 1 BR
            drawDetectionTagCorner [- $ROWS 1] 0 0 BL
        }} $name $detection]
    }]

    set homButtons [lmap {i H} [lenumerate $Hs] {
        button .$name.h$i -text H$i -command [list apply {{name sideLength detection H} {
            .$name.canv delete all
            .$name.canv create rectangle 4 4 [- 1280 2] [- 720 2] -outline red
            # Model points, from the known geometry of the checkerboard (in
            # meters, where top-left corner of top-left AprilTag is 0, 0).
            set ROWS 4
            set COLS 6
            for {set row 0} {$row < $ROWS} {incr row} {
                for {set col 0} {$col < $COLS} {incr col} {
                    set corners [list]
                    lappend corners [list [* $col $sideLength 2] \
                                       [+ [* $row $sideLength 2] $sideLength]] ;# bottom-left

                    lappend corners [list [+ [* $col $sideLength 2] $sideLength] \
                                       [+ [* $row $sideLength 2] $sideLength]] ;# bottom-right

                    lappend corners [list [+ [* $col $sideLength 2] $sideLength] \
                                       [* $row $sideLength 2]] ;# top-right

                    lappend corners [list [* $col $sideLength 2] [* $row $sideLength 2]] ;# top-left

                    set corners [lmap corner $corners {matmul $H [list {*}$corner 1]}]
                    set corners [lmap corner $corners {
                        lassign $corner cx cy cz
                        list [/ $cx $cz] [/ $cy $cz]
                    }]
                    .$name.canv create line {*}[join $corners] {*}[lindex $corners 0]
                }
            }
        }} $name $sideLength [lindex $detections $i] $H]
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

        # Compute unrefined camera intrinsics:
        lassign $b B11 B12 B22 B13 B23 B33
        set v0 [expr {($B12*$B13 - $B11*$B23) / ($B11*$B22 - $B12*$B12)}]
        set lambda [expr {$B33 - ($B13*$B13 + $v0*($B12*$B13 - $B11*$B23))/$B11}]
        set alpha [expr {sqrt($lambda/$B11)}]
        set beta [expr {sqrt($lambda*$B11/($B11*$B22 - $B12*$B12))}]
        set gamma [expr {-$B12*$alpha*$alpha*$beta/$lambda}]
        set u0 [expr {$gamma*$v0/$beta - $B13*$alpha*$alpha/$lambda}]

        puts "Unrefined Camera Intrinsics:"
        puts "=============================="
        puts "   Focal Length: \[ $alpha $beta ]"
        puts "Principal Point: \[ $u0 $v0 ]"
        puts "           Skew: \[ $gamma ] "
        puts ""

        # Unrefined camera intrinsic matrix:
        set A [subst {
            {$alpha $gamma $u0}
            {     0  $beta $v0}
            {     0      0   1}
        }]

        # Compute extrinsics for each of the images (needed so we can
        # do the reprojection during nonlinear refinement)
        proc recoverExtrinsics {H K} {
            set h0 [getcol $H 0]
            set h1 [getcol $H 1]
            set h2 [getcol $H 2]

            set Kinv [solvePGauss $K [mkIdentity 3]]
            set lambda_ [/ 1.0 [norm [matmul $Kinv $h0]]]

            set r0 [scale $lambda_ [matmul $Kinv $h0]]
            set r1 [scale $lambda_ [matmul $Kinv $h1]]
            set r2 [crossproduct $r0 $r1]
            set t [scale $lambda_ [matmul $Kinv $h2]]

            set R [transpose [list $r0 $r1 $r2]]
            # Reorthogonalize R:
            lassign [determineSVD $R] U S V
            set R [matmul $U [transpose $V]]

            # Reconstitute full extrinsics:
            return [show [transpose [list {*}[transpose $R] $t]]]
        }
        foreach H $Hs {
            puts [recoverExtrinsics $H $K]
        }

        proc reprojectionError {} {

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
