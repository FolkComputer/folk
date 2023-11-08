source "lib/language.tcl"
namespace eval Evaluator { source "lib/environment.tcl" }

lappend auto_path "./vendor"
package require math::linearalgebra
foreach p {add norm sub scale leastSquaresSVD matmul
           getelem transpose determineSVD} {
    namespace import ::math::linearalgebra::$p
}

package require math::geometry
namespace import ::math::geometry::pointInsidePolygon

apply {{} {

set ROWS 4
set COLS 5
# The model is a dictionary whose keys are tag IDs and where each
# value is a dictionary with keys `center` and `corners` which are
# model points (x, y). The tags on the outer perimeter will get
# projected to PostScript points and printed; the tags in the
# interior will get projected to Vulkan points and rendered on
# projector.
set ::MODEL [apply {{ROWS COLS} {
    set MODEL [dict create]

    set tagSideLength 1.0
    set tagOuterLength [expr {$tagSideLength * 10/6}]
    set pad $tagSideLength
    for {set row 0} {$row < $ROWS} {incr row} {
        for {set col 0} {$col < $COLS} {incr col} {
            set id [expr {48600 + $row*$COLS + $col}]
            set modelX [expr {($tagOuterLength + $pad)*$col}]
            set modelY [expr {($tagOuterLength + $pad)*$row}]
            # Now modelX and modelY are the top-left outer corner of
            # the tag.
            set modelX [expr {$modelX + ($tagOuterLength - $tagSideLength)/2}]
            set modelY [expr {$modelY + ($tagOuterLength - $tagSideLength)/2}]
            # Now modelX and modelY are the top-left inner corner of
            # the tag.
            set modelTopLeft [list $modelX $modelY]
            set modelTopRight [list [+ $modelX $tagSideLength] $modelY]
            set modelBottomRight [list [+ $modelX $tagSideLength] [+ $modelY $tagSideLength]]
            set modelBottomLeft [list $modelX [+ $modelY $tagSideLength]]
            set modelTag [dict create \
                              center [scale 0.5 [add $modelTopLeft $modelBottomRight]] \
                              corners [list $modelBottomLeft $modelBottomRight \
                                          $modelTopRight $modelTopLeft]]
            dict set MODEL $id $modelTag
        }
    }
    return $MODEL
}} $ROWS $COLS]

fn isCalibrationTag {id} { expr {$id >= 48600 && $id < 48600 + $ROWS*$COLS} }
fn isPrintedTag {id} {
    if {![isCalibrationTag $id]} { return false }
    # We print tags on the outer perimeter of the grid, and we project
    # tags in the interior.
    set idx [- $id 48600]
    set row [expr {$idx / $COLS}]
    set col [expr {$idx % $COLS}]
    return [expr {$row == 0 || $row == $ROWS - 1 ||
                  $col == 0 || $col == $COLS - 1}]
}
fn isProjectedTag {id} {
    if {![isCalibrationTag $id]} { return false }
    ! [isPrintedTag $id]
}

# Takes a list of at least 4 point pairs (model -> image) like
#
# [list \
#   [list x0 y0 u0 v0]] \
#   [list x1 y1 u1 v1] \
#   [list x2 y2 u2 v2] \
#   [list x3 y3 u3 v3]]
#
# Returns a 3x3 homography that maps model (x, y) to image (u, v)
# (using homogeneous coordinates).
fn estimateHomography {pointPairs} {
    set A [list]
    set b [list]
    foreach pair $pointPairs {
        lassign $pair x y u v
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
fn applyHomography {H xy} {
    lassign [matmul $H [list {*}$xy 1]] u v w
    return [list [/ $u $w] [/ $v $w]]
}

fn processHomography {H} {
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

    set V [list \
               [v 1 2] \
               [sub [v 1 1] [v 2 2]]]
    return $V
}

# Uses Zhang's calibration technique
# (https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr98-71.pdf)
# to calibrate a projector or camera given a known 2D planar pattern
# and multiple observed poses.
#
# Returns intrinsic matrix for the camera/projector, which explains
# how 3D real-world coordinates get projected to 2D coordinates by
# that device. (The intrinsic matrix can be used with an AprilTag
# detector to get real-world coordinates for each AprilTag.)
#
# Arguments:
#         Hs   a list of N homographies from camera/projector image
#              plane -> model plane (for N different poses).
fn zhangCalibrate {Hs} {
    # Try to solve for the camera intrinsics:

    # Construct V:
    set Vtop [list]; set Vbottom [list]
    foreach H $Hs {
        lassign [processHomography $H] Vtop_ Vbottom_
        lappend Vtop $Vtop_
        lappend Vbottom $Vbottom_
    }
    set V [list {*}$Vtop {*}$Vbottom]
    assert {[::math::linearalgebra::shape $V] eq [list [* 2 [llength $Hs]] 6]}

    # Solve Vb = 0:
    lassign [determineSVD [matmul [transpose $V] $V]] U S V'
    set b [lindex [transpose ${V'}] [lindex [lsort -real -indices $S] 0]]

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

    puts "   Focal Length: \[ $alpha $beta ]"
    puts "Principal Point: \[ $u0 $v0 ]"
    puts "           Skew: \[ $gamma ] "

    # TODO: nlopt for better intrinsics + distortion parameters
}

# sideLength is inner side length of a tag, in meters.
# calibrationPoses is a list of N dictionaries of detected tags.
fn calibrate {sideLength calibrationPoses} {
    # MODEL's 2D coordinates have inner tag side length of 1.0: scale
    # it up to real-world coordinates.
    set model [dict map {id tag} $::MODEL {
        dict create center [scale $sideLength [dict get $tag center]] \
            corners [scale $sideLength [dict get $tag corners]]
    }]

    # First, calibrate the camera. "Using only the corners from
    # printed markers xb and their detected corners xc, [...]
    # calibrate the camera with no difficulties using Zhang’s method."
    set Hs_cameraToModel [lmap pose $calibrationPoses {
        # Pairs of (camera coordinates, model coordinates).
        set pointPairs [list]
        dict for {id cameraTag} $pose {
            if {![isPrintedTag $id]} continue
            set modelTag [dict get $model $id]
            foreach modelCorner [dict get $modelTag corners] \
                cameraCorner [dict get $cameraTag corners] {
                    lappend pointPairs [list {*}$cameraCorner {*}$modelCorner]
                }
        }
        estimateHomography $pointPairs
    }]
    set cameraIntrinsics [zhangCalibrate $Hs_cameraToModel]

    # Second, calibrate the projector.
    set Hs_projectorToModel [lmap pose $calibrationPoses {
        # Homography from projector -> camera.
        

        # Homography from camera -> model.


        # pairs of (projector coordinates, model coordinates).
        # but... what is a projector coordinate...
        set pointPairs [list]
        dict for {id cameraTag} $pose {
            if {![isProjectedTag $id]} continue
            set modelTag [dict get $model $id]
            foreach modelCorner [dict get $modelTag corners] \
                poseCorner [dict get $poseTag corners] {
                    lappend pointPairs [list {*}$modelCorner {*}$poseCorner]
                }
        }
        estimateHomography $pointPairs
    }]
    set projectorIntrinsics [zhangCalibrate $Hs_projectorToModel]
}


set fd [open "$::env(HOME)/Code/folk/calibrationposes.txt" r]
eval [read $fd]; close $fd
calibrate [/ 17.5 1000] $calibrationPoses

}}
