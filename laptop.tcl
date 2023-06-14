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
    wm title . $::nodename
    wm geometry . [set Display::WIDTH]x[expr {$Display::HEIGHT + 40}]-0+0 ;# align to top-right of screen

    proc init {} {}

    proc fillRect {x0 y0 x1 y1 color} {
        uplevel [list Wish display runs [list .display create rectangle $x0 $y0 $x1 $y1 -fill $color]]
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list .display create line {*}[join $points] -fill $color -width $width]]
    }

    proc text {fb x y fontSize text {radians 0}} {
        # TODO: @cwervo - implement font rotation
        uplevel [list Wish display runs [list .display create text $x $y -text $text -font "Helvetica [expr {$fontSize * 12}]" -fill white]]
    }

    variable displayTime
    proc commit {} {
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

set ::chs [list]
proc handleKeyPress {k} {
    lappend ::chs $k
    Retract keyboard claims the keyboard character log is /something/
    Assert keyboard claims the keyboard character log is $::chs
    Step
}
bind . <KeyPress> {handleKeyPress %K}

Assert when /program/ has error /err/ with info /info/ {{program err info} {
    puts stderr "Error: $program has error $err with info $info"
}}

source "hosts.tcl"
if {[info exists ::shareNode]} {
    # copy to Pi
    if {[catch {
        # TODO: forward entry point
        # TODO: handle rsync strict host key failure
        exec -ignorestderr make sync FOLK_SHARE_NODE=$::shareNode
        exec -ignorestderr ssh folk@$::shareNode -- sudo systemctl restart folk >@stdout &
    } err]} {
        puts "error syncing: $err"
        puts "Proceeding without sharing to table."

    } else {
        source "lib/peer.tcl"
        peer $::shareNode

        Assert "laptop.tcl" is providing root statements
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" is providing root statements]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" claims /program/ has program code /code/]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" claims /program/ has region /region/]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" wishes to print /code/ with job id /jobid/]
    }
}

Display::init
Step

vwait forever
