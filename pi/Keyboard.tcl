namespace eval Keyboard {
    source "pi/KeyCodes.tcl"

    variable kb

    proc init {} {
        variable kb
        # Get the list of all /dev/input/event* files
        set allDevices [glob -nocomplain "/dev/input/event*"]
        # Prepare a list to hold keyboard devices
        set keyboardDevices {}
        # Loop through each device file
        foreach device $allDevices {
            # Get udevadm information for the device
            set deviceInfo [exec udevadm info --query=property --name=$device]

            # Check if it's a keyboard by looking for "ID_INPUT_KEYBOARD=1" in the udevadm output
            if {[string first "ID_INPUT_KEYBOARD=1" $deviceInfo] >= 0} {
                # It's a keyboard, add to list of keyboard devices
                lappend keyboardDevices $device
            }
        }

        foreach device $keyboardDevices {
            if {[file readable $device] == 0} {
                puts "Device $device is not readable. Attempting to change permissions."
                # Attempt to change permissions so that the file can be read
                exec sudo chmod +r $device
            }

            set kb [open [lindex $keyboardDevices 0] r]
        }
        fconfigure $kb -translation binary
    }

    proc getChar {} {
        # See https://www.kernel.org/doc/Documentation/input/input.txt
        # https://www.kernel.org/doc/Documentation/input/event-codes.txt
        # https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
        #
        # struct input_event {
        #     struct timeval time;
        #     unsigned short type; (should be EV_KEY = 0x01)
        #     unsigned short code; (scancode; for example, 16 = q)
        #     unsigned int value; (should be 1 for keypress)
        # };
        #
        while 1 {
            binary scan [read $Keyboard::kb 16] nntutunu tvSec tvUsec type code value
            if {$type == 0x01 && $value == 1} break
        }
        # TODO: Should properly catch this error
        # e.g. Jan 28 04:11:28 folk0 make[1991]: Thread error: tid0x7f45fd2b0640 can't\ read\ \"name\":\ no\ such\ variable ...

        # scancode name, like KEY_A
        catch { set name [dict get $Keyboard::KeyCodes $code] } err
        set ch [string tolower [string range $name 4 end]]
        # puts "type $type code $code value $value ($ch)"
        return $ch
    }
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    Keyboard::init
    puts [Keyboard::getChar]
    puts [Keyboard::getChar]
    puts [Keyboard::getChar]
}
