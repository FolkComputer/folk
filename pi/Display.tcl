package require critcl
source "pi/critclUtils.tcl"

critcl::tcl 8.6
critcl::cflags -Wall -Werror

critcl::ccode {
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <sys/mman.h>
    #include <stdint.h>
    uint16_t* fbmem;
}
critcl::ccode [source "vendor/font.tcl"]
opaquePointerType uint16_t*

critcl::cproc mmapFb {int width int height} uint16_t* {
    int fb = open("/dev/fb0", O_RDWR);
    fbmem = mmap(NULL, width * height * 2, PROT_WRITE, MAP_SHARED, fb, 0);
    return fbmem;
}
critcl::cproc clearCInner {int width int x0 int y0 int x1 int y1 char* color} void {
    unsigned short colorShort = (color[1] << 8) | color[0];
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            fbmem[(y * width) + x] = colorShort;
        }
    }
}
critcl::cproc drawChar {int width int x0 int y0 char* cs} void {
    char c = cs[0];
    /* printf("%d x %d\n", font.char_width, font.char_height); */
    /* printf("[%c] (%d)\n", c, c); */

    for (unsigned y = 0; y < font.char_height; y++) {
        for (unsigned x = 0; x < font.char_width; x++) {
            int idx = (c * font.char_height * 2) + (y * 2) + (x >= 8 ? 1 : 0);
            int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
            fbmem[((y0 + y) * width) + (x0 + x)] = bit ? 0xFFFF : 0x0000;
        }
    }
}

namespace eval Display {
    variable WIDTH
    variable HEIGHT

    variable black [binary format b16 [join {00000 000000 00000} ""]]
    variable blue  [binary format b16 [join {11111 000000 00000} ""]]
    variable green [binary format b16 [join {00000 111111 00000} ""]]
    variable red   [binary format b16 [join {00000 000000 11111} ""]]

    variable fb
    
    # functions
    # ---------
    proc init {} {
        regexp {mode "(\d+)x(\d+)"} [exec fbset] -> Display::WIDTH Display::HEIGHT
        set Display::fb [mmapFb $Display::WIDTH $Display::HEIGHT]
    }

    proc fillRect {fb x0 y0 x1 y1 color} {
        clearCInner $Display::WIDTH [expr int($x0)] [expr int($y0)] [expr int($x1)] [expr int($y1)] [set Display::$color]
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $Display::WIDTH $Display::HEIGHT $color
    }

    proc text {fb x y fontSize text} {
        foreach char [split $text ""] {
            drawChar $Display::WIDTH [expr int($x)] [expr int($y)] $char
            incr x 9 ;# TODO: don't hardcode font width
        }
    }
}

catch {if {$::argv0 eq [info script]} {
    Display::init
    drawChar $Display::WIDTH 300 400 "A"
    drawChar $Display::WIDTH 309 400 "B"
    drawChar $Display::WIDTH 318 400 "O"

    Display::text fb 300 420 PLACEHOLDER "Hello!"
}}
