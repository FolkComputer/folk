package require Thread
proc errorproc {args} {puts "Thread error: $args"}
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

# Camera thread
namespace eval Camera {
    variable WIDTH 1280
    variable HEIGHT 720
    variable statements [list]

    variable cameraThread [thread::create [format {
        source pi/Camera.tcl
        Camera::init %d %d
        AprilTags::init
        puts "Camera tid: [getTid]"

        set grayFrames [list]
        while true {
            # Hack: we free old images. Really this should be done on
            # the main thread when it's actually done with them.
            if {[llength $grayFrames] > 10} {
                freeImage [lindex $grayFrames 0]
                set grayFrames [lreplace $grayFrames 0 0]
            }
            set cameraTime [time {
                set grayFrame [Camera::grayFrame]
                set tags [AprilTags::detect $grayFrame]
                lappend grayFrames $grayFrame
            }]
            set statements [list]
            lappend statements [list camera claims the camera time is $cameraTime]
            lappend statements [list camera claims the camera frame is $grayFrame]
            foreach tag $tags {
                lappend statements [list camera claims tag [dict get $tag id] has center [dict get $tag center] size [dict get $tag size]]
                lappend statements [list camera claims tag [dict get $tag id] has corners [dict get $tag corners]]
            }

            # send this script back to the main Folk thread
            # puts "\n\nCommands\n-----\n[join $commands \"\n\"]"
            thread::send -async "%s" [list set Camera::statements $statements]
        }
    } $WIDTH $HEIGHT [thread::id]]]
    puts "Camera thread id: $cameraThread"

    Assert when $::nodename has step count /c/ {{c} {
        foreach stmt $Camera::statements {
            Say {*}$stmt
        }
    }}
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

# also see how it's done in laptop.tcl
set ::rootStatements [list]
proc loadProgram {programFilename} {
    # this is a proc so its variables don't leak
    set fp [open $programFilename r]
    lappend ::rootStatements [list root claims $programFilename has program code [read $fp]]
    # set x 0; set y 100; set w 100; set h 100
    # set vertices [list [list $x $y] \
    #                   [list [expr {$x+$w}] $y] \
    #                   [list [expr {$x+$w}] [expr {$y+$h}]] \
    #                   [list $x [expr {$y+$h}]]]
    # set edges [list [list 0 1] [list 1 2] [list 2 3] [list 3 0]]
    # lappend ::rootStatements [list root claims $programFilename has region [list $vertices $edges]]
    close $fp
}
foreach programFilename [glob virtual-programs/*.folk] {
    loadProgram $programFilename
}
foreach programFilename [glob -nocomplain "user-programs/[info hostname]/*.folk"] {
    loadProgram $programFilename
}

# so we can retract them all at once if a laptop connects:
Assert when the collected matches for [list /someone/ is providing root statements] are /roots/ {{roots} {
    if {[llength $roots] == 0} {
        foreach stmt $::rootStatements { Say {*}$stmt }
    }
}}

proc every {ms body} {
    try $body
    after $ms [list after idle [namespace code [info level 0]]]
}
every 32 { Step }

vwait forever
