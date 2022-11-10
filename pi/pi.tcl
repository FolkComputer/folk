package require Thread

namespace eval Display {
    variable surface

    variable displayThread [thread::create {
        source pi/Display.tcl
        Display::init
        puts "Display tid: [getTid]"

        set ::displayCount 0
        thread::wait
    }]
    puts "Display thread id: $displayThread"
    variable surface [thread::send $displayThread [list set Display::surface]]

    proc stroke {surface points width color} {
        uplevel [list Wish display runs [list Display::stroke $surface $points $width $color]]
    }

    proc text {surface x y fontSize text} {
        uplevel [list Wish display runs [list Display::text $surface $x $y $fontSize $text]]
    }

    proc commit {} {
        set displayList [list]
        foreach match [Statements::findMatches [list /someone/ wishes display runs /command/]] {
            lappend displayList [dict get $match command]
        }
        foreach smatch [Statements::findMatches [list /someone/ claims /thing/ has drawable surface /surface/]] {
            set thing [dict get $smatch thing]
            set surface [dict get $smatch surface]
            foreach rmatch [Statements::findMatches [list /someone/ claims $thing has region /region/]] {
                set region [dict get $rmatch region]
                lappend displayList [list Display::drawSurface $Display::surface {*}[lindex $region 0 0] 0 $surface]
            }
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
            %s
            # (slow, should be abortable by newcomer commits)

            commitThenClearStaging
        } $::displayCount [join [lsort -command lcomp $displayList] "\n"]]
    }
}

# Camera thread
namespace eval Camera {
    variable statements [list]

    variable cameraThread [thread::create [format {
        source pi/Camera.tcl
        Camera::init 1280 720
        AprilTags::init
        puts "Camera tid: [getTid]"

        set frame 0
        while true {
            if {$frame != 0} {freeImage $frame}
            set cameraTime [time {
                set frame [Camera::frame]

                set grayFrame [rgbToGray $frame $Camera::WIDTH $Camera::HEIGHT]
                set tags [AprilTags::detect $grayFrame]
                freeImage $grayFrame
            }]
            set statements [list]
            lappend statements [list camera claims the camera time is $cameraTime]
            lappend statements [list camera claims the camera frame is $frame]
            foreach tag $tags {
                lappend statements [list camera claims tag [dict get $tag id] has center [dict get $tag center] size [dict get $tag size]]
                lappend statements [list camera claims tag [dict get $tag id] has corners [dict get $tag corners]]
            }

            # send this script back to the main Folk thread
            # puts "\n\nCommands\n-----\n[join $commands \"\n\"]"
            thread::send -async "%s" [list set Camera::statements $statements]
        }
    } [thread::id]]]
    puts "Camera thread id: $cameraThread"

    Assert when $::nodename has step count /c/ {
        foreach stmt $Camera::statements {
            Say {*}$stmt
        }
    }
}

set keyboardThread [thread::create [format {
    source pi/Keyboard.tcl
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

# also see how it's done in laptop.tcl
set rootStatements [list]
foreach programFilename [glob virtual-programs/*.folk] {
    set fp [open $programFilename r]
    lappend rootStatements [list root claims $programFilename has program code [read $fp]]
    lappend rootStatements [list root claims $programFilename is a rectangle with x 0 y 100 width 100 height 100]
    close $fp
}

# so we can retract them all at once if a laptop connects
Assert $::nodename has root statements $rootStatements

Assert when $::nodename has root statements /statements/ {
    foreach stmt $statements { Say {*}$stmt }
}

proc every {ms body} {
    try $body
    after $ms [list after idle [namespace code [info level 0]]]
}
every 32 { Step }

vwait forever
