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

apply {{} {
    source "lib/c.tcl"
    source "virtual-programs/calibrate/calibrate.folk"
    set ::MODEL $MODEL
    source "virtual-programs/calibrate/refine.folk"
    source "virtual-programs/calibrate/calibration-test.folk"

    set fd [open "folk-calibration-poses.txt" r]
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

    # Test without refinement (refiner is identity fn).
    calibrate $calibrationPoses {{poses calibration} {set calibration}}

    # Test with refinement.
    calibrate $calibrationPoses $::refineCalibration
}}
