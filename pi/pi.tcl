package require Thread

namespace eval Display {
    variable WIDTH HEIGHT
    regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT

    variable displayThread [thread::create {
        source pi/Display.tcl
        Display::init

        thread::wait
    }]
    puts "dt $displayThread"

    proc fillRect {fb x0 y0 x1 y1 color} {
        uplevel [list Wish display runs [list Display::fillRect $fb $x0 $y0 $x1 $y1 $color]]
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list Display::stroke $points $width $color]]
    }

    proc text {fb x y fontSize text} {
        uplevel [list Wish display runs [list Display::text $fb $x $y $fontSize $text]]
    }

    proc commit {} {
        set displayList [list]
        foreach match [Statements::findMatches {/someone/ wishes display runs /command/}] {
            lappend displayList [dict get $match command]
        }

        proc lcomp {a b} {expr {[lindex $a 0] == "Display::text"}}
        thread::send -async $Display::displayThread [format {
            # Draw the display list
            %s
            # (slow, should be abortable by newcomer commits)

            commitThenClearStaging
        } [join [lsort -command lcomp $displayList] "\n"]]
    }
}

# Camera thread
set cameraThread [thread::create [format {
    source pi/Camera.tcl
    Camera::init 1280 720
    AprilTags::init

    set frame 0
    set generation 0
    while true {
        if {$frame != 0} {freeImage $frame}
        set cameraTime [time {
            set frame [Camera::frame]

            set grayFrame [rgbToGray $frame $Camera::WIDTH $Camera::HEIGHT]
            set tags [AprilTags::detect $grayFrame]
            freeImage $grayFrame
        }]
        set commands [list]
        lappend commands [list set ::cameraTime $cameraTime]

        foreach tag $tags {
            lappend commands [list Assert camera claims tag [dict get $tag id] has center [dict get $tag center] size [dict get $tag size] with generation $generation]
            lappend commands [list Assert camera claims tag [dict get $tag id] has corners [dict get $tag corners] with generation $generation]
        }
        # Retract prev claims
        lappend commands [list Retract camera claims the camera frame is /something/] \
            [list Assert camera claims the camera frame is "$frame"] \
            [list Retract camera claims tag /something/ has corners /something/ with generation [expr {$generation - 1}]] \
            [list Retract camera claims tag /something/ has center /something/ size /something/ with generation [expr {$generation - 1}]]

        # send this script back to the main Folk thread
        # puts "\n\nCommands\n-----\n[join $commands \"\n\"]"
        thread::send -async "%s" [join $commands "\n"]

        incr generation
    }
} [thread::id]]]
puts "ct $cameraThread"

set keyboardThread [thread::create [format {
    source pi/Keyboard.tcl
    Keyboard::init

    set chs [list]
    while true {
        lappend chs [Keyboard::getChar]

        thread::send -async "%s" [subst {
            Retract keyboard claims the keyboard character log is /something/
            Assert keyboard claims the keyboard character log is "$chs"
        }]
    }
} [thread::id]]]
puts "kt $keyboardThread"

proc every {ms body} {
    try $body
    after $ms [list after idle [namespace code [info level 0]]]
}
every 32 {Step}

vwait forever
