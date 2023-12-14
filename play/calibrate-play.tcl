lappend auto_path "./vendor"
source "lib/language.tcl"
namespace eval Evaluator { source "lib/environment.tcl" }
proc Wish {args} {}
proc When {args} {
    if {[lrange $args 0 end-1] eq [list the calibration model is /MODEL/]} {
        set body [lindex $args end]
        set MODEL $::MODEL
        eval $body
        set ::refineCalibration $refineCalibration
    }
}
proc Claim {args} {}

proc testCalibration {calibrationPoses calibration} {
    upvar ^isProjectedTag ^isProjectedTag
    upvar ^applyHomography ^applyHomography

    set tagSize [expr {17.0 / 1000}]; # 17 mm
    set tagFrameCorners \
        [list [list [expr {-$tagSize/2}] [expr {$tagSize/2}]  0] \
              [list [expr {$tagSize/2}]  [expr {$tagSize/2}]  0] \
              [list [expr {$tagSize/2}]  [expr {-$tagSize/2}] 0] \
              [list [expr {-$tagSize/2}] [expr {-$tagSize/2}] 0]]

    set cameraIntrinsics [dict get $calibration camera intrinsics]
    set cameraFx [getelem $cameraIntrinsics 0 0]
    set cameraFy [getelem $cameraIntrinsics 1 1]
    set cameraCx [getelem $cameraIntrinsics 0 2]
    set cameraCy [getelem $cameraIntrinsics 1 2]
    set cameraK1 [dict get $calibration camera k1]
    set cameraK2 [dict get $calibration camera k2]

    # https://yangyushi.github.io/code/2020/03/04/opencv-undistort.html
    # https://stackoverflow.com/questions/61798590/understanding-legacy-code-algorithm-to-remove-radial-lens-distortion
    set undistort {{fx fy cx cy k1 k2 xy} {
        lassign $xy x y
        set x [expr {($x - $cx)/$fx}]
        set y [expr {($y - $cy)/$fy}]
        for {set i 0} {$i < 3} {incr i} {
            set r2 [expr {$x*$x + $y*$y}]
            set rad [expr {1.0 + $k1 * $r2 + $k2 * $r2*$r2}]
            set x [expr {$x / $rad}]
            set y [expr {$y / $rad}]
        }
        return [list [expr {$x*$fx + $cx}] [expr {$y*$fy + $cy}]]
    }}

    set projectorIntrinsics [dict get $calibration projector intrinsics]
    set projectorFx [getelem $projectorIntrinsics 0 0]
    set projectorFy [getelem $projectorIntrinsics 1 1]
    set projectorCx [getelem $projectorIntrinsics 0 2]
    set projectorCy [getelem $projectorIntrinsics 1 2]
    set projectorK1 [dict get $calibration projector k1]
    set projectorK2 [dict get $calibration projector k2]

    set R_cameraToProjector [dict get $calibration R_cameraToProjector]
    set t_cameraToProjector [dict get $calibration t_cameraToProjector]

    # package require Tk
    # canvas .canv -width 1920 -height 1080 -background white
    # pack .canv -fill both -expand true

    set totalError 0

    foreach calibrationPose $calibrationPoses {
        dict for {id cameraTag} [dict get $calibrationPose tags] {
            if {![isProjectedTag $id]} continue

            # Before estimating pose, undistort the corners of
            # cameraTag using the camera distortion coefficients.
            # TODO: This doesn't fixup the homography in cameraTag.
            dict set cameraTag p [lmap cameraCorner [dict get $cameraTag p] {
                apply $undistort $cameraFx $cameraFy $cameraCx $cameraCy \
                    $cameraK1 $cameraK2 \
                    $cameraCorner
            }]
            set tagPose [estimateTagPose $cameraTag $tagSize \
                             $cameraFx $cameraFy $cameraCx $cameraCy]
            for {set i 0} {$i < 4} {incr i} {
                set modelPoint [lindex [dict get $calibrationPose model $id p] $i]
                # .canv create oval {*}[scale 1000 $modelPoint] {*}[add [scale 1000 $modelPoint] {5 5}] -fill red

                set H_modelToDisplay [dict get $calibrationPose H_modelToDisplay]
                lassign [applyHomography $H_modelToDisplay $modelPoint] origX origY
                # .canv create oval $origX $origY {*}[add [list $origX $origY] {5 5}] -fill green
                # puts ""

                set tagFrameCorner [lindex $tagFrameCorners $i]
                set cameraFrameCorner [lrange [matmul $tagPose [list {*}$tagFrameCorner 1]] 0 2]

                set projectorFrameCorner [add [matmul $R_cameraToProjector $cameraFrameCorner] $t_cameraToProjector]
                lassign [matmul $projectorIntrinsics $projectorFrameCorner] rpx rpy rpz
                set idealReprojX [/ $rpx $rpz]; set idealReprojY [/ $rpy $rpz]
                # .canv create oval $reprojX $reprojY {*}[add [list $reprojX $reprojY] {5 5}] -fill yellow

                # Distort idealReprojX and idealReprojY using the
                # distortion coefficients.
                set x [expr {($idealReprojX - $projectorCx)/$projectorFx}]
                set y [expr {($idealReprojY - $projectorCy)/$projectorFy}]
                set r [expr {sqrt($x*$x + $y*$y)}]
                set D [expr {$projectorK1 * $r*$r + $projectorK2 * $r*$r*$r*$r}]
                set reprojX [expr {$idealReprojX * (1.0 + $D)}]
                set reprojY [expr {$idealReprojY * (1.0 + $D)}]

                puts "$id (corner $i): orig projected x y: $origX $origY"
                puts "$id (corner $i): reprojected x y:    $reprojX $reprojY"
                puts ""

                # puts "$id (corner $i): cameraFrameCorner ($cameraFrameCorner)"
                # puts "$id (corner $i): projectorFrameCorner ($projectorFrameCorner)"
                # puts ""

                lassign [matmul $cameraIntrinsics $cameraFrameCorner] rcx rcy rcz
                # puts "$id (corner $i): orig camera x y:   [lindex [dict get $calibrationPose tags $id p] $i]"
                # puts "$id (corner $i): reproj camera x y: [/ $rcx $rcz] [/ $rcy $rcz]"
                # puts ""

                set error [expr {sqrt(($reprojX - $origX)*($reprojX - $origX) + ($reprojY - $origY)*($reprojY - $origY))}]
                set totalError [+ $totalError $error]
            }
        }
    }

    puts "TOTAL ERROR: $totalError"
}

apply {{} {
    source "lib/c.tcl"
    source "virtual-programs/calibrate/calibrate.folk"
    set ::MODEL $MODEL
    source "virtual-programs/calibrate/refine.folk"
    source "virtual-programs/calibrate/calibration-test.folk"

    set fd [open "folk-calibration-poses-folk0-threshold-1.txt" r]
    set calibrationPoses [read $fd]; close $fd

    # Emit files into ~/aux/CameraCalibration/ for testing:
    apply {{calibrationPoses} {
        set cameraDir "$::env(HOME)/aux/CameraCalibration/folk-calibration-poses-camera-data"
        catch { exec mkdir $cameraDir }

        set model [dict get [lindex $calibrationPoses 0] model]
        # Dictionary that maps (model point) -> list of up to NUM_POSES pose points.
        set points [dict create]
        dict for {id modelTag} $model {
            foreach modelCorner [dict get $modelTag p] {
                dict set points $modelCorner [list]
            }
        }

        foreach calibrationPose $calibrationPoses {
            # Emit camera data.
            dict for {id cameraTag} [dict get $calibrationPose tags] {
                set modelTag [dict get $calibrationPose model $id]
                for {set i 0} {$i < 4} {incr i} {
                    set modelPoint [lindex [dict get $modelTag p] $i]
                    dict lappend points $modelPoint [lindex [dict get $cameraTag p] $i] 
                }
            }
        }

        set modelFd [open "$cameraDir/model.txt" w]
        set poseFds [list]
        for {set i 0} {$i < [llength $calibrationPoses]} {incr i} {
            lappend poseFds [open "$cameraDir/$i.txt" w]
        }
        dict for {modelPoint posePoints} $points {
            if {[llength $posePoints] < [llength $calibrationPoses]} {
                continue
            }
            puts -nonewline $modelFd "$modelPoint "
            foreach poseFd $poseFds posePoint $posePoints {
                puts -nonewline $poseFd "$posePoint "
            }
        }

        close $modelFd; foreach poseFd $poseFds { close $poseFd }
    }} $calibrationPoses

    puts "Test without refinement (refiner is identity fn)."
    puts "-------------------------------------------------"
    set unrefinedCalibration [calibrate $calibrationPoses {{poses cal} {set cal}}]
    testCalibration $calibrationPoses $unrefinedCalibration

    puts ""
    puts "Test with refinement."
    puts "-------------------------------------------------"
    testCalibration $calibrationPoses [calibrate $calibrationPoses $::refineCalibration]

    # puts ""
    # puts "Test with hard-coding."
    # puts "-------------------------------------------------"
    # lassign {1368.51525 1372.89528} fx fy
    # lassign {922.51410  570.47142} cx cy
    # set s -6.0599534
    # dict set unrefinedCalibration camera intrinsics [subst {
    #     {$fx   $s  $cx}
    #     {  0  $fy  $cy}
    #     {  0    0    1}
    # }]
    # testCalibration $calibrationPoses $unrefinedCalibration
}}
