package require Tk

# text .t
# pack .t -expand true -fill both
# .t insert end {blah blah blah}

# periodically request samples
# connect to the peer
# set chan [socket folk.local 4273]
# puts "got [gets $chan]"
# close $chan

namespace eval Display {
    variable WIDTH 800
    variable HEIGHT 600
    canvas .display -background black -width $WIDTH -height $HEIGHT
    pack .display

    variable black black
    variable blue  blue
    variable green green
    variable red   red

    proc fillRect {fb x0 y0 x1 y1 color} {
        .display create rectangle $x0 $y0 $x1 $y1 -fill $color
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $WIDTH $HEIGHT $color
    }
}
