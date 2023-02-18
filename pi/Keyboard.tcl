namespace eval Keyboard {
    source "pi/KeyCodes.tcl"

    variable kb

    proc init {} {
        variable kb
        if {[info hostname] eq "folk0"} {
            set kb [open "/dev/input/by-path/pci-0000:02:00.0-usb-0:2:1.2-event-mouse" r]
        } elseif {[info hostname] eq "folk-omar"} {
            # This path is set based on the keyboard unique MAC
            # address by a udev rule on machine.
            while {![file exists "/dev/input/btkeyboard-omar-gray"]} {
                puts "Keyboard not found, waiting."
                exec sleep 2
            }
            set kb [open "/dev/input/btkeyboard-omar-gray" r]
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
