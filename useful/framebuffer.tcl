set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

# $ fbset
# mode "1920x1080"
#     geometry 1920 1080 1920 1080 16
#     timings 0 0 0 0 0 0 0
#     accel true
#     rgba 5/11,6/5,5/0,0/0
# endmode

# bgr
# blue: set color [binary format b16 1111100000000000]
set color [binary format b16 1111100000000000]
for {set y 0} {$y < 1080} {incr y} {
    for {set x 0} {$x < 1920} {incr x} {
        puts -nonewline $fb $color
    }
}


