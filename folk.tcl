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

proc calibrate_folk {} {
    exec tclsh8.6 ~/folk/calibrate.tcl
}

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
    default {
        puts $availableActions
    }
}
