source pi/Display.tcl

Display::init

package require Thread
set ::cameraThread [thread::create]
thread::send -async $::cameraThread [format {
    source pi/Camera.tcl
    Camera::init
    AprilTags::init

    while true {
        set frame [Camera::frame]

        set commands [list "Retract camera claims the camera frame is /something/" \
                          "Assert camera claims the camera frame is \"$frame\"" \
                          "Retract camera claims tag /something/ has center /something/ size /something/"]

        set tags [AprilTags::detect [yuyv2gray $frame $Camera::WIDTH $Camera::HEIGHT]]
        foreach tag $tags {
            lappend commands "Assert camera claims tag [dict get $tag id] has center [dict get $tag center] size [dict get $tag size]"
        }

        lappend commands "Step {}"

        # send this script back to the main Folk thread
        thread::send -async "%s" [join $commands "\n"]
    }
} [thread::id]]
