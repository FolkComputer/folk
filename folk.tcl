#!/usr/bin/env tclsh8.6

set availableActions "Invalid action for manage_folk. Available actions: start, stop, restart"

proc manage_folk {action} {
    switch -- $action {
        "start" -
        "stop" -
        "restart" {
            exec sudo systemctl $action folk
        }
        default {
            puts $availableActions
        }
    }
}

# Function to calibrate folk
proc calibrate_folk {} {
    exec tclsh8.6 ~/folk/calibrate.tcl
}

# Function to setup camera for folk
proc setup_camera_folk {} {
    exec sudo systemctl stop folk
    exec tclsh8.6 ~/folk/pi/Camera.tcl
}

# Main Program
if {$argc == 0} {
    puts "Usage: folk <command>"
    puts $availableActions
    exit 1
}

set command [lindex $argv 0]

switch -- $command {
    "start" -
    "stop" -
    "restart" {
        manage_folk $command
    }
    "calibrate" {
        calibrate_folk
    }
    "setup" {
        if {[lindex $argv 1] eq "camera"} {
            setup_camera_folk
        } else {
            puts "Invalid setup option. Did you mean 'setup camera'?"
        }
    }
    default {
        puts $availableActions
    }
}
