package require Thread

namespace eval Display {
    variable displayThread [thread::create {
        source pi/Display.tcl
        Display::init

        thread::wait
    }]
    puts "dt $displayThread"

    variable displayList

    proc fillRect {fb x0 y0 x1 y1 color} {
        lappend Display::displayList "Display::fillRect $fb $x0 $y0 $x1 $y1 $color"
    }
    proc fillScreen {fb color} {
        lappend Display::displayList "Display::fillScreen $fb $color"
    }

    proc text {fb x y fontSize text} {
        lappend Display::displayList "Display::text $fb $x $y $fontSize $text"
    }

    proc commit {} {
        thread::send -async $Display::displayThread [format {
            # Allocate a new, clear framebuffer
            

            # Draw the display list
            %s

            # (slow, should be abortable by newcomer commits)

            # Copy the framebuffer onto the screen

            # Free the framebuffer

        } $Display::displayList]
        
        # Make a new display list with a clear screen
    }
}

# Camera thread
set cameraThread [thread::create [format {
    source pi/Camera.tcl
    Camera::init
    AprilTags::init

    while true {
        set frame [Camera::frame]

        set commands [list "Retract camera claims the camera frame is /something/" \
                          "Assert camera claims the camera frame is \"$frame\"" \
                          "Retract camera claims tag /something/ has center /something/ size /something/"]

        set grayFrame [yuyv2gray $frame $Camera::WIDTH $Camera::HEIGHT]
        set tags [AprilTags::detect $grayFrame]
        freeGray $grayFrame

        foreach tag $tags {
            lappend commands "Assert camera claims tag [dict get $tag id] has center {[dict get $tag center]} size [dict get $tag size]"
        }

        lappend commands "Step {}"

        # send this script back to the main Folk thread
        thread::send -async "%s" [join $commands "\n"]
    }
} [thread::id]]]
puts "ct $cameraThread"
