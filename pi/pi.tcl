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

    variable displayList [list]

    proc fillRect {fb x0 y0 x1 y1 color} {
        lappend Display::displayList [list Display::fillRect $fb $x0 $y0 $x1 $y1 $color]
    }

    proc stroke {points width color} {
        lappend Display::displayList [list Display::stroke $points $width $color]
    }

    proc text {fb x y fontSize text} {
        lappend Display::displayList [list Display::text $fb $x $y $fontSize $text]
    }

    proc commit {} {
        thread::send -async $Display::displayThread [format {
            # Draw the display list
            %s
            # (slow, should be abortable by newcomer commits)

            commitThenClearStaging
        } [join $Display::displayList "\n"]]
        
        # Make a new display list
        set Display::displayList [list]
    }
}

# Camera thread
set cameraThread [thread::create [format {
    source pi/Camera.tcl
    Camera::init 1280 720
    AprilTags::init

    set frame 0
    while true {
        if {$frame != 0} {freeImage $frame}
        set cameraTime [time {
            set frame [Camera::frame]

            set commands [list "Retract camera claims the camera frame is /something/" \
                              "Assert camera claims the camera frame is \"$frame\"" \
                              "Retract camera claims tag /something/ has corners /something/" \
                              "Retract camera claims tag /something/ has center /something/ size /something/"]

            set grayFrame [rgbToGray $frame $Camera::WIDTH $Camera::HEIGHT]
            set tags [AprilTags::detect $grayFrame]
            freeImage $grayFrame
        }]
        lappend commands [list set ::cameraTime $cameraTime]

        foreach tag $tags {
            lappend commands [list Assert camera claims tag [dict get $tag id] has center [dict get $tag center] size [dict get $tag size]]
            lappend commands [list Assert camera claims tag [dict get $tag id] has corners [dict get $tag corners]]
        }

        # send this script back to the main Folk thread
        thread::send -async "%s" [join $commands "\n"]
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
every 32 {Step {}}
