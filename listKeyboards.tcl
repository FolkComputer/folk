#!/usr/bin/env tclsh8.6

# This Tcl script lists all keyboard devices in the /dev/input/ directory.

puts "Working ..."

proc udevadm_properties {device} {
    return [exec udevadm info --query=property --name=$device]
}

proc devpath  {device} {
    return [exec udevadm info --query=property --name=$device | grep DEVPATH=]
}

# Function to check if the device is a keyboard
proc is_keyboard {device} {
    # Get device properties using udevadm
    set udev_info [udevadm_properties $device]
    # Check for the property that identifies the device as a keyboard
    return [string match *ID_INPUT_KEYBOARD=1* $udev_info]
}

# Iterate over all event devices and check if they are keyboards
set eventInputs [glob -nocomplain /dev/input/event*]

foreach device $eventInputs {
    if {[is_keyboard $device]} {
        puts "-- Keyboard found: $device | [devpath $device]\n-------\n"
    }
}

puts "Done listing keyboards."
