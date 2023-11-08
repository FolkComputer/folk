namespace eval Keyboard {
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
                puts "---------\ngot device $device"
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

    # Event size depends on sizeof(long). Default to 32-bit longs
    variable evtBytes 16
    variable evtFormat iissi
    if {[exec getconf LONG_BIT] == 64} {
      set evtBytes 24
      set evtFormat wwssi
    }

    proc getKeyEvent {} {
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
            binary scan [read $Keyboard::kb $evtBytes] $evtFormat tvSec tvUsec type code value
            if {$type == 0x01} {
                return [list $code $value]
            }
        }
    }
}
