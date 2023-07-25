package require Thread
proc errorproc {id errorInfo} {puts "Thread error in $id: $errorInfo"}
thread::errorproc errorproc

namespace eval Display {
    variable WIDTH
    variable HEIGHT
    variable LAYER 0
    regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT

    variable displayThread [thread::create {
        source pi/Display.tcl
        Display::init
        puts "Display tid: [getTid]"

        set ::displayCount 0
        thread::wait
    }]
    puts "Display thread id: $displayThread"

    proc drawOnTop {func args} {
        set Display::LAYER 1
        uplevel [list $func {*}$args]
        set Display::LAYER 0
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list Display::stroke $points $width $color] on layer $Display::LAYER]
    }

    proc circle {x y radius thickness color} {
        uplevel [list Wish display runs [list Display::circle $x $y $radius $thickness $color] on layer $Display::LAYER]
    }

    proc text args {
        uplevel [list Wish display runs [list Display::text {*}$args] on layer $Display::LAYER]
    }

    proc fillTriangle args {
        uplevel [list Wish display runs [list Display::fillTriangle {*}$args] on layer $Display::LAYER]
    }

    proc fillQuad args {
        uplevel [list Wish display runs [list Display::fillQuad {*}$args] on layer $Display::LAYER]
    }

    proc fillPolygon args {
        uplevel [list Wish display runs [list Display::fillPolygon {*}$args] on layer $Display::LAYER]
    }

    variable displayTime none
    proc commit {} {
        set displayList [list]
        foreach match [Statements::findMatches {/someone/ wishes display runs /command/ on layer /layer/}] {
            lappend displayList [list [dict get $match layer] [dict get $match command]]
        }

        proc lcomp {a b} {
            set layerA [lindex $a 0]
            set layerB [lindex $b 0]
            if {$layerA == $layerB} {
                expr {[lindex $a 1 0] == "Display::text"}
            } else {
                expr {$layerA - $layerB}
            }
        }

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
          [join [lmap sublist [lsort -command lcomp $displayList] {lindex $sublist 1}] "\n"] \
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

loadVirtualPrograms
forever { Step }
