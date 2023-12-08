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

    set tagSize [expr {17.5 / 1000}]; # 17.5 mm
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
    set projectorIntrinsics [dict get $calibration projector intrinsics]

    set R_cameraToProjector [dict get $calibration R_cameraToProjector]
    set t_cameraToProjector [dict get $calibration t_cameraToProjector]

    # package require Tk
    # canvas .canv -width 1920 -height 1080 -background white
    # pack .canv -fill both -expand true

    set totalError 0

    foreach calibrationPose $calibrationPoses {
        dict for {id cameraTag} [dict get $calibrationPose tags] {
            if {![isProjectedTag $id]} continue

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
                set reprojX [/ $rpx $rpz]; set reprojY [/ $rpy $rpz]
                # .canv create oval $reprojX $reprojY {*}[add [list $reprojX $reprojY] {5 5}] -fill yellow
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

    puts "Test without refinement"
    puts "-------------------------------------------------"
    set unrefinedCalibration [calibrate $calibrationPoses]
    testCalibration $calibrationPoses $unrefinedCalibration

    puts "Test WITH refinement"
    puts "-------------------------------------------------"
    set refinedCalibration [apply $::refineCalibration \
                                [/ 17.5 1000] $calibrationPoses \
                                $unrefinedCalibration]
    puts "Refined calibration is ($refinedCalibration)"
    testCalibration $calibrationPoses $refinedCalibration
}}
