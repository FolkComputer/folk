package require Tk

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
        fillRect $fb 0 0 $Display::WIDTH $Display::HEIGHT $color
    }

    proc text {fb x y fontSize text} {
        .display create text $x $y -text $text -font "Helvetica $fontSize" -fill white
    }
}

package require Thread
set ::sharerThread [thread::create]
proc StepFromGUI {} {
    Step {
        puts "StepFromGUI"
    }
    # share statement set to Pi
    # folk0.local 4273
    thread::send -async $::sharerThread [format {
        catch {
            set sock [socket "folk0.local" 4273]
            # FIXME: should _retract_ only our asserted statements
            puts $sock "set ::assertedStatements {%s}; Step {}"
            close $sock
        }
    } $::statements]
}

set ::nextProgramNum 0
proc newProgram {} {
    set programNum [incr ::nextProgramNum]
    set program program$programNum

    toplevel .$program
    wm title .$program $program
    wm geometry .$program 350x250+[expr {20 + $programNum*20}]+[expr {20 + $programNum*20}]

    text .$program.t
    pack .$program.t -expand true -fill both

    proc handleSave {program} {
        # display save
        catch {destroy .$program.saved}
        label .$program.saved -text Saved!
        place .$program.saved -x 40 -y 100
        after 500 "catch {destroy .$program.saved}"

        Retract "laptop.tcl" claims $program has program code /something/
        Assert "laptop.tcl" claims $program has program code [.$program.t get 1.0 end]

        StepFromGUI
    }
    bind .$program <Control-Key-s> [list handleSave $program]
    proc handleConfigure {program x y w h} {
        Retract "laptop.tcl" claims $program is a rectangle with x /something/ y /something/ width /something/ height /something/
        Assert "laptop.tcl" claims $program is a rectangle with x $x y $y width $w height $h

        StepFromGUI
    }
    bind .$program <Configure> [subst -nocommands {
        if {"%W" eq [winfo toplevel %W]} {
            handleConfigure $program %x %y %w %h
        }
    }]
}
button .btn -text "New Program" -command newProgram
pack .btn
