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
set blue  [binary format b16 [join {11111 000000 00000} ""]]
set green [binary format b16 [join {00000 111111 00000} ""]]

# takes ~1,700,000 us (~1.7s)
proc clearTcl {fb color} {
    seek $fb 0
    for {set y 0} {$y < 1080} {incr y} {
        for {set x 0} {$x < 1920} {incr x} {
            puts -nonewline $fb $color
        }
    }
    seek $fb 0
}

puts [time {clearTcl $fb $green}]
puts [time {clearTcl $fb $blue}]

# this doesn't work right, but it's close:
# (it's also not actually faster, lol)
package require critcl
critcl::cproc clearC {char* fbHandle char* color} void {
    int fb;
    sscanf(fbHandle, "file%d", &fb);

    lseek(fb, 0, SEEK_SET);
    for (int y = 0; y < 1080; y++) {
        for (int x = 0; x < 1920; x++) {
            write(fb, color, 2);
        }
    }
    lseek(fb, 0, SEEK_SET);
}

puts [time {clearC $fb $green}]
puts [time {clearC $fb $blue}]

# ideas:
# - clear in C
# - reduce resolution
# - use Vulkan
# - use simd
