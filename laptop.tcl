namespace eval Display {
    variable WIDTH 800
    variable HEIGHT 600

    variable black black
    variable blue  blue
    variable green green
    variable red   red

    proc init {} {
        package require Tk

        canvas .display -background black -width $Display::WIDTH -height $Display::HEIGHT
        pack .display
        wm title . $::thisProcess
        wm geometry . [set Display::WIDTH]x[expr {$Display::HEIGHT + 40}]-0+0 ;# align to top-right of screen

        set ::chs [list]
        bind . <KeyPress> {apply {{k} {
            lappend ::chs $k
            Retract keyboard claims the keyboard character log is /something/
            Assert keyboard claims the keyboard character log is $::chs
            Step
        }} %K}

        proc ::Display::commit {} {
            .display delete all

            set displayList [list]
            foreach match [Statements::findMatches {/someone/ wishes display runs /command/}] {
                lappend displayList [dict get $match command]
            }

            proc lcomp {a b} {expr {[lindex $a 2] == "text"}}
            variable displayTime
            set displayTime [time {
                eval [join [lsort -command lcomp $displayList] "\n"]
            }]
        }
    }

    proc fillRect {x0 y0 x1 y1 color} {
        uplevel [list Wish display runs [list .display create rectangle $x0 $y0 $x1 $y1 -fill $color]]
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list .display create line {*}[join $points] -fill $color -width $width]]
    }

    proc text {x y scale text {radians 0}} {
        uplevel [list Wish display runs [list .display create text $x $y -text $text -font "Helvetica [expr {$scale * 12}]" -fill white -anchor center -angle [expr {$radians/3.14159*180}]]]
    }

    variable displayTime

    # No-op until Display::init is called.
    proc commit {} {}
}

Assert when /program/ has error /err/ with info /info/ {{program err info} {
    puts stderr "Error: $program has error $err with info $info"
}}

source "hosts.tcl"
if {[info exists ::shareNode]} {
    puts "Will try to share with: $::shareNode"
    # copy to Pi
    if {[catch {
        # TODO: forward entry point
        # TODO: handle rsync strict host key failure
        exec -ignorestderr make sync FOLK_SHARE_NODE=$::shareNode
        exec -ignorestderr ssh folk@$::shareNode -- sudo systemctl restart folk >@stdout &
    } err]} {
        puts "error syncing: $err"
        puts "Proceeding without sharing."

    } else {
        source "lib/peer.tcl"
        peer $::shareNode

        Assert "laptop.tcl" wishes $::thisProcess shares statements like \
            [list $::thisProcess is providing root virtual programs /rootVirtualPrograms/]
    }
}

try {
    Display::init
} on error e {
    puts stderr "Failed to init display: $e"
}
loadVirtualPrograms
Step

vwait forever
