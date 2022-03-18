package require Tk

# text .t
# pack .t -expand true -fill both
# .t insert end {blah blah blah}

# periodically request samples
# connect to the peer
# set chan [socket folk.local 4273]
# puts "got [gets $chan]"
# close $chan

namespace eval Display {
    variable WIDTH 800
    variable HEIGHT 600
    canvas .display -background black -width $WIDTH -height $HEIGHT
    pack .display

    variable black black
    variable blue  blue
    variable green green
    variable red   red

    proc fillRect {fb x0 y0 x1 y1 color} {
        .display create rectangle $x0 $y0 $x1 $y1 -fill $color
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $WIDTH $HEIGHT $color
    }
}

proc StepFromProgramConfigure {} {
    Step {
        puts StepFromProgramConfigure
        When /rect/ is a rectangle with x /x/ y /y/ width /width/ height /height/ {
            When /someone/ wishes $rect is highlighted /color/ {
                # it's not really correct to just stick a side-effect in the
                # When handler like this. but we did it in Realtalk, and it
                # was ok, so whatever for now
                Display::fillRect device $x $y [expr $x+$width] [expr $y+$height] $color
            }
            Wish $rect is highlighted $Display::blue
        }
    }
}

set ::nextProgramNum 0
proc newProgram {} {
    set programNum [incr ::nextProgramNum]
    set program .program$programNum

    toplevel $program
    wm title $program $program
    wm geometry $program 350x250+[expr {20 + $programNum*20}]+[expr {20 + $programNum*20}]

    text $program.t
    pack $program.t -expand true -fill both
    # TODO: respond to Save and exec code

    bind $program <Configure> [subst -nocommands {
        if {"%W" eq [winfo toplevel %W]} {
            puts "reconfigured %W: (%x,%y) %wx%h"
            Retract "laptop.tcl" claims $program is a rectangle with x /something/ y /something/ width /something/ height /something
            Assert "laptop.tcl" claims $program is a rectangle with x "%x" y "%y" width "%w" height "%h"

            StepFromProgramConfigure
        }
    }]
}
button .btn -text "New Program" -command newProgram
pack .btn
