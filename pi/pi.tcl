package require Thread
proc errorproc {id errorInfo} {puts "Thread error in $id: $errorInfo"}
thread::errorproc errorproc

namespace eval Display {
    variable WIDTH
    variable HEIGHT
    regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT

    variable displayThread [thread::create {
        source pi/Display.tcl
        Display::init
        puts "Display tid: [getTid]"

        set ::displayCount 0
        thread::wait
    }]
    puts "Display thread id: $displayThread"

    proc stroke {points width color} {
        uplevel [list Wish display runs [list Display::stroke $points $width $color]]
    }

    proc circle {x y radius thickness color} {
        uplevel [list Wish display runs [list Display::circle $x $y $radius $thickness $color]]
    }

    proc text {fb x y fontSize text {radians 0}} {
        uplevel [list Wish display runs [list Display::text $fb $x $y $fontSize $text $radians]]
    }

    proc fillTriangle args {
        uplevel [list Wish display runs [list Display::fillTriangle {*}$args]]
    }

    proc fillQuad args {
        uplevel [list Wish display runs [list Display::fillQuad {*}$args]]
    }

    proc fillPolygon args {
        uplevel [list Wish display runs [list Display::fillPolygon {*}$args]]
    }

    variable displayTime none
    proc commit {} {
        set displayList [list]
        foreach match [Statements::findMatches {/someone/ wishes display runs /command/}] {
            lappend displayList [dict get $match command]
        }

        proc lcomp {a b} {expr {[lindex $a 0] == "Display::text"}}
        incr ::displayCount
        thread::send -head -async $Display::displayThread [format {
            set newDisplayCount %d
            if {$::displayCount > $newDisplayCount} {
                # we've already displayed a newer frame
                return
            } else {
                set ::displayCount $newDisplayCount
            }
 
            # Draw the display list
            set displayTime [time {
                %s
                commitThenClearStaging
            }]
            thread::send -async "%s" [subst {
                set Display::displayTime "$displayTime"
            }]
        } $::displayCount \
          [join [lsort -command lcomp $displayList] "\n"] \
          [thread::id]]
    }
}

try {
    set keyboardThread [thread::create [format {
        source "pi/Keyboard.tcl"
        source "lib/c.tcl"
        source "pi/cUtils.tcl"
        Keyboard::init
        puts "Keyboard tid: [getTid]"

        set chs [list]
        while true {
            lappend chs [Keyboard::getChar]

            thread::send -async "%s" [subst {
                Retract keyboard claims the keyboard character log is /something/
                Assert keyboard claims the keyboard character log is "$chs"
            }]
        }
    } [thread::id]]]
    puts "Keyboard thread id: $keyboardThread"
} on error error {
    puts stderr "Keyboard thread failed: $error"
}

proc every {ms body} {
    try $body
    after $ms [list after idle [namespace code [info level 0]]]
}
every 32 { Step }

loadVirtualPrograms
Step

vwait forever
