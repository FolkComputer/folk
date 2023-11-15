namespace eval Keyboard {
    variable kb
    variable keyboards

    proc udevadmProperties {device} {
        return [exec udevadm info --query=property --name=$device]
    }

    proc getDEVLINKS {device} {
        set properties [udevadmProperties $device]
        if {$properties eq ""} {
            return ""
        }
        set devlinks [list]
        foreach line [split $properties \n] {
            if {[string match "DEVLINKS=*" $line]} {
                set devlinks [string replace $line 0 8]
                foreach path [split $devlinks " "] {
                    lappend devlinks $path
                }
            }
        }

        return $devlinks
    }

    proc establishKeyPressListener {eventPath} {
        set kb [open $eventPath r]
        fconfigure $kb -translation binary
        return $kb
    }

    # Function to check if the device is a keyboard
    proc isKeyboard {device} {
        set properties [udevadmProperties $device]
        if {$properties eq ""} {
            return false
        }
        set isKeyboard [string match *ID_INPUT_KEYBOARD=1* $properties]
        return $isKeyboard
        # TODO: Excluding mice would nice to keey the list of keyboard devices short
        #       Alas, including mice is necessary for the Logitech K400R keyboard
        # set isMouse [string match *ID_INPUT_MOUSE=1* $properties]
        # return [expr {$isKeyboard && !$isMouse}]
    }

    ####
    # /dev/input/event* addresses are the ground truth for keyboard devices
    #
    # This function goes through

    proc walkInputEventPaths {} {
        set allDevices [glob -nocomplain "/dev/input/event*"]
        set keyboards [list]
        foreach device $allDevices {
            set devLinks [getDEVLINKS $device]
            if {[llength $devLinks] > 0 && [isKeyboard $device]} {
                if {[file readable $device] == 0} {
                    puts "Device $device is not readable. Attempting to change permissions."
                    # Attempt to change permissions so that the file can be read
                    exec sudo chmod +r $device
                }
                lappend keyboards [dict create eventPath $device devLinks $devLinks]
            }
        }
        return $keyboards
    }

    proc getDefaultKeyboard {} {
        return $Keyboard::kb
    }

    proc init {} {
        variable kb
        variable keyboards

        set keyboardDevices [walkInputEventPaths]
        set keyboards $keyboardDevices

        puts "=== Keyboard devices ([llength $keyboardDevices])"
        set firstKeyboard [dict get [lindex $keyboardDevices 0] eventPath]
        set kb [establishKeyPressListener $firstKeyboard]
        puts "=== Opened keyboard device: $firstKeyboard \\ $kb"
    }

    # Event size depends on sizeof(long). Default to 32-bit longs
    variable evtBytes 16
    variable evtFormat iissi
    if {[exec getconf LONG_BIT] == 64} {
      set evtBytes 24
      set evtFormat wwssi
    }

    proc getKeyEvent {{keyboardSpecifier ""} args} {
        set keyboardStream $Keyboard::kb
        if {$keyboardSpecifier ne ""} {
            set keyboardStream [dict get $Keyboard::keyboards $keyboardSpecifier]
        }
        # TODO: Allow keyboardSpecifier to be a keyboard device file
        # e.g. /dev/input/by-path/platform-i8042-serio-0-event-kbd
        variable evtBytes
        variable evtFormat

        # See https://www.kernel.org/doc/Documentation/input/input.txt
        # https://www.kernel.org/doc/Documentation/input/event-codes.txt
        # https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
        #
        # struct input_event {
        #     struct timeval time;
        #     unsigned short type; (should be EV_KEY = 0x01)
        #     unsigned short code; (scancode; for example, 16 = q)
        #     unsigned int value; (0 for key release, 1 for press, 2 for repeat)
        # };
        #
        while 1 {
            binary scan [read $keyboardStream $evtBytes] $evtFormat tvSec tvUsec type code value
            if {$type == 0x01} {
                return [list $code $value]
            }
        }
    }
}