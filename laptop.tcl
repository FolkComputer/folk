package require Tk

namespace eval Display {
    variable WIDTH 800
    variable HEIGHT 600

    variable black black
    variable blue  blue
    variable green green
    variable red   red

    canvas .display -background black -width $Display::WIDTH -height $Display::HEIGHT
    pack .display
    wm geometry . [set Display::WIDTH]x[expr {$Display::HEIGHT + 40}]-0+0 ;# align to top-right of screen
    proc init {} {}

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
            puts $sock {dict set ::assertedStatementsFrom "%s" {%s}}
            close $sock
        }
    } $::nodename $::statements]
}

set ::nextProgramNum 0
set defaultCode {Wish $this is highlighted blue}
proc newProgram "{programCode {$defaultCode}} {programFilename 0}" {
    set programNum [incr ::nextProgramNum]
    if {$programFilename != 0} {
        set program [string map {. ^} $::nodename:$programFilename]
    } else {
        set program [string map {. ^} $::nodename]:program$programNum
    }

    toplevel .$program
    wm title .$program $program
    wm geometry .$program 350x250+[expr {20 + $programNum*20}]+[expr {20 + $programNum*20}]

    text .$program.t
    .$program.t insert 1.0 $programCode
    pack .$program.t -expand true -fill both
    focus .$program.t

    proc handleSave {program programFilename} {
        # https://wiki.tcl-lang.org/page/Text+processing+tips
        set code [.$program.t get 1.0 end-1c]

        # display save
        catch {destroy .$program.saved}
        if {$programFilename != 0} {
            set fp [open $programFilename w]
            puts -nonewline $fp $code
            close $fp
            label .$program.saved -text "Saved to $programFilename!"
        } else {
            label .$program.saved -text "Saved!"
        }
        place .$program.saved -x 40 -y 100
        after 500 "catch {destroy .$program.saved}"

        Retract "laptop.tcl" claims $program has program code /something/
        Assert "laptop.tcl" claims $program has program code $code

        StepFromGUI
    }
    bind .$program <Control-Key-s> [list handleSave $program $programFilename]
    proc handleConfigure {program x y w h} {
        Retract "laptop.tcl" claims $program is a rectangle with x /something/ y /something/ width /something/ height /something/
        Assert "laptop.tcl" claims $program is a rectangle with x $x y $y width $w height $h

        StepFromGUI
    }
    bind .$program <Configure> [subst -nocommands {
        # HACK: we get some weird stray Configure event
        # where w and h are 1, so ignore that
        if {"%W" eq [winfo toplevel %W] && %w > 1} {
            handleConfigure $program %x %y %w %h
        }
    }]

    handleSave $program $programFilename
}
button .btn -text "New Program" -command newProgram
pack .btn
bind . <Control-Key-n> newProgram

foreach programFilename [glob programs/*.folk] {
    set fp [open $programFilename r]
    newProgram [read $fp] $programFilename
    close $fp
}

Display::init
