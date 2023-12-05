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

    # Test without refinement (refiner is identity fn).
    calibrate $calibrationPoses {{poses calibration} {set calibration}}

    # Test with refinement.
    calibrate $calibrationPoses $::refineCalibration
}}
