namespace eval Evaluator { source "lib/environment.tcl" }
source "lib/language.tcl"

lappend auto_path "./vendor"
package require math::linearalgebra
rename ::scale scaleTk
namespace import ::math::linearalgebra::*

proc findHomography {sideLength detection} {
    set ROWS 4
    set COLS 6

    # x0 and y0 are camera points, from the camera image.
    fn detectionTagCorner {row col corner} {
        set id [expr {48600 + $row*$COLS + $col}]
        return [lindex [dict get [dict get $detection $id] corners] $corner]
    }

    lassign [detectionTagCorner 0 0 3] x0 y0 ;# top-left
    lassign [detectionTagCorner 0 [- $COLS 1] 2] x1 y1 ;# top-right
    lassign [detectionTagCorner [- $ROWS 1] [- $COLS 1] 1] x2 y2 ;# bottom-right    
    lassign [detectionTagCorner [- $ROWS 1] 0 0] x3 y3 ;# bottom-left

    lassign [detectionTagCorner 0 [expr {$COLS/2 - 1}] 3] x4 y4 ;# top-center (tl corner)
    lassign [detectionTagCorner [- $ROWS 1] [expr {$COLS/2 - 1}] 0] x5 y5 ;# bottom-center (bl corner)

    # u0 and v0 are model points, from the known geometry of the
    # checkerboard (in meters, where top-left corner of top-left
    # AprilTag is 0, 0).
    set u0 0; set v0 0
    set u1 [* $COLS $sideLength 2]; set v1 0
    set u2 [* $COLS $sideLength 2]; set v2 [* $ROWS $sideLength 2]
    set u3 0; set v3 [* $ROWS $sideLength 2]

    set u4 [expr {($COLS/2) * $sideLength * 2}]; set v4 0
    set u5 [expr {($COLS/2) * $sideLength * 2}]; set v5 [* $ROWS $sideLength 2]

    puts "Image: $x0 $y0 $x1 $y1 $x2 $y2 $x3 $y3 $x4 $y4 $x5 $y5"
    puts "Model: $u0 $v0 $u1 $v1 $u2 $v2 $u3 $v3 $u4 $v4 $u5 $v5"

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
        # {$x4 $y4 1 0   0   0 [expr -$x4*$u4] [expr -$y4*$u4]}
        # {$x5 $y5 1 0   0   0 [expr -$x5*$u5] [expr -$y5*$u5]}
        # {0   0   0 $x4 $y4 1 [expr -$x4*$v4] [expr -$y4*$v4]}
        # {0   0   0 $x5 $y5 1 [expr -$x5*$v5] [expr -$y5*$v5]}
    
    set b [list $u0 $u1 $u2 $u3 $v0 $v1 $v2 $v3]

    lassign [solvePGauss $A $b] a0 a1 a2 b0 b1 b2 c0 c1
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

proc loadDetections {name detections} {
    toplevel .$name

    set Hs [lmap detection $detections {
        findHomography [/ 12 1000.0] $detection
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

        # Compute camera intrinsic matrix A:
        lassign $b B11 B12 B22 B13 B23 B33
        puts $b
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
        loadDetections $name $detections
    }} $path $name]]
}
pack {*}$loadButtons -fill both -expand true

vwait forever
