source "folk.tcl"

# Wish "/dev/fb0" shows a rectangle with x 0 y
# "<window UUID>" wishes "/dev/fb0" shows a rectangle with x 0 y 0
# (I want to invoke that from a window on my laptop which has a UUID.)

# TODO: use Vulkan (-:
set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

regexp {mode "(\d+)x(\d+)"} [exec fbset] -> ::WIDTH ::HEIGHT

set black [binary format b16 [join {00000 000000 00000} ""]]
set blue  [binary format b16 [join {11111 000000 00000} ""]]
set green [binary format b16 [join {00000 111111 00000} ""]]
set red   [binary format b16 [join {00000 000000 11111} ""]]

proc fbFillRect {fb x0 y0 x1 y1 color} {
    for {set y $y0} {$y < $y1} {incr y} {
        seek $fb [expr (($y * $::WIDTH) + $x0) * 2]
        for {set x $x0} {$x < $x1} {incr x} {
            puts -nonewline $fb $color
        }
    }
}
proc fbFillScreen {fb color} {
    fbFillRect $fb 0 0 $::WIDTH $::HEIGHT $color
}

When /someone/ wishes /device/ shows a rectangle with \
    x /x/ y /y/ width /width/ height /height/ fill /color/ {
        # it's not really correct to just stick a side-effect in the
        # When handler like this. but we did it in Realtalk, and it
        # was ok, so whatever for now
        fbFillRect $device $x $y [expr $x + $width] [expr $y + $height] $color
}

Wish $fb shows a rectangle with x 150 y 50 width 30 height 40 fill $blue

# with key1 /value1/ key2 /value2/
# With all /matches/
# To know when

proc step {} {
    global fb black green

    # clear the screen
    fbFillScreen $fb $green

    # infinite event loop
    # event: an incoming statement bundle
    # a statement bundle includes statements and statement-retractions
    # do peers need to connect? or is it like a message thing?
    # there needs to be a persistent statement database?
    frame
    # is there an effect set that comes out of the frame?
    
    # stream effects/output statement set outward?
    # (for now, draw all the graphics requests)
}
after 0 step

vwait forever
