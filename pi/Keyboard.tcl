namespace eval Keyboard {
    source "pi/KeyCodes.tcl"

    variable kb

    proc init {} {
        variable kb
        set kb [open "/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse" r]
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
        set name [dict get $Keyboard::KeyCodes $code] ;# scancode name, like KEY_A
        set ch [string tolower [string range $name 4 end]]
        # puts "type $type code $code value $value ($ch)"
        return $ch
    }
}

if {$::argv0 eq [info script]} {
    Keyboard::init
    puts [Keyboard::getChar]
    puts [Keyboard::getChar]
    puts [Keyboard::getChar]
}
