lappend auto_path "./vendor"
source "lib/language.tcl"
namespace eval Evaluator { source "lib/environment.tcl" }
proc Wish {args} {}
proc When {args} {}

apply {{} {
    source "virtual-programs/calibrate/calibrate.folk"

    set fd [open "$::env(HOME)/Code/folk/calibrationposes4-folk0.txt" r]
    eval "set calibrationPoses [read $fd]"; close $fd

    calibrate $calibrationPoses
}}
