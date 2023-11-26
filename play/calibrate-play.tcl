lappend auto_path "./vendor"
source "lib/language.tcl"
namespace eval Evaluator { source "lib/environment.tcl" }
proc Wish {args} {}
proc When {args} {}

apply {{} {
    source "virtual-programs/calibrate/calibrate.folk"
    source "lib/c.tcl"
    source "virtual-programs/calibrate/calibration-test.folk"

    set fd [open "folk-calibration-poses.txt" r]
    set calibrationPoses [read $fd]; close $fd
    calibrate $calibrationPoses
}}
