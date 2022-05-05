set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

# $ fbset
# mode "1920x1080"
#     geometry 1920 1080 1920 1080 16
#     timings 0 0 0 0 0 0 0
#     accel true
#     rgba 5/11,6/5,5/0,0/0
# endmode

# $ fbset
# mode "4096x2160"
#     geometry 4096 2160 4096 2160 16
#     timings 0 0 0 0 0 0 0
#     accel true
#     rgba 5/11,6/5,5/0,0/0
# endmode

regexp {mode "(\d+)x(\d+)"} [exec fbset] -> ::WIDTH ::HEIGHT

# bgr
set black [binary format b16 [join {00000 000000 00000} ""]]
set white [binary format b16 [join {11111 111111 11111} ""]]
set blue  [binary format b16 [join {11111 000000 00000} ""]]
set green [binary format b16 [join {00000 111111 00000} ""]]
set red   [binary format b16 [join {00000 000000 11111} ""]]

# takes ~1,700,000 us (~1.7s)
proc clearTcl {fb color} {
    seek $fb 0
    for {set y 0} {$y < $::HEIGHT} {incr y} {
        for {set x 0} {$x < $::WIDTH} {incr x} {
            puts -nonewline $fb $color
        }
    }
    seek $fb 0
}

# puts {clearTcl $fb $green}
# puts [time {clearTcl $fb $green}]
# puts {clearTcl $fb $red}
# puts [time {clearTcl $fb $red}]

package require critcl
critcl::ccode {
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <sys/mman.h>
    char* fbmem;
}
critcl::cproc mmapFb {char* fbHandle int width int height} void {
    int fb = open("/dev/fb0", O_RDWR);
    fbmem = mmap(NULL, width * height * 2, PROT_WRITE, MAP_SHARED, fb, 0);
}

critcl::cproc clearCInner {int width int height bytes color} void {
    int i = 0;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            fbmem[i++] = color.s[0];
            fbmem[i++] = color.s[1];
        }
    }
}
proc clearC {fbHandle color} { clearCInner $::WIDTH $::HEIGHT $color }

mmapFb $fb $::WIDTH $::HEIGHT

set routine {clearC $fb $blue}
puts $routine
puts [time $routine]

set routine {clearC $fb $red}
puts $routine
puts [time $routine]

# ideas:
# - clear in C
# - reduce resolution
# - use Vulkan
# - use simd
