# Wish "/dev/fb0" shows a rectangle with x 0 y
# "<window UUID>" wishes "/dev/fb0" shows a rectangle with x 0 y 0
# (I want to invoke that from a window on my laptop which has a UUID.)

# TODO: use Vulkan (-:
set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

namespace eval Display {
    variable WIDTH
    variable HEIGHT
    regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT

    variable black [binary format b16 [join {00000 000000 00000} ""]]
    variable blue  [binary format b16 [join {11111 000000 00000} ""]]
    variable green [binary format b16 [join {00000 111111 00000} ""]]
    variable red   [binary format b16 [join {00000 000000 11111} ""]]

    proc fillRect {fb x0 y0 x1 y1 color} {
        for {set y $y0} {$y < $y1} {incr y} {
            seek $fb [expr (($y * $WIDTH) + $x0) * 2]
            for {set x $x0} {$x < $x1} {incr x} {
                puts -nonewline $fb $color
            }
        }
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $WIDTH $HEIGHT $color
    }
}
