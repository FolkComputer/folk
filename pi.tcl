# prep stuff
# ----------
package require critcl
critcl::ccode {
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <sys/mman.h>
    unsigned short* fbmem;
}
# i think you need to run critcl::ccode here, not in the imported module
# for it to get compiled with all our other C code in this file?
critcl::ccode [source "vendor/font.tcl"]

critcl::cproc mmapFb {int width int height} void {
    int fb = open("/dev/fb0", O_RDWR);
    fbmem = mmap(NULL, width * height * 2, PROT_WRITE, MAP_SHARED, fb, 0);
}
critcl::cproc clearCInner {int width int x0 int y0 int x1 int y1 bytes color} void {
    unsigned short colorShort = (color.s[1] << 8) | color.s[0];
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
            int bit = (font.font_bitmap[idx] >> (7 - (x % 8))) & 0x01;
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

    # functions
    # ---------
    proc init {} {
        regexp {mode "(\d+)x(\d+)"} [exec fbset] -> Display::WIDTH Display::HEIGHT
        mmapFb $Display::WIDTH $Display::HEIGHT
    }

    proc fillRect {fb x0 y0 x1 y1 color} {
        clearCInner $Display::WIDTH $x0 $y0 $x1 $y1 [set Display::$color]
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $Display::WIDTH $Display::HEIGHT $color
    }

    proc text {fb x y fontSize text} {
        foreach char [split $text ""] {
            drawChar $Display::WIDTH $x $y $char
            incr x 9 ;# TODO: don't hardcode font width
        }
    }
}

if {$::argv0 eq [info script]} {
    # WIP: working on text rendering
    Display::init
    drawChar $Display::WIDTH 300 400 "A"
    drawChar $Display::WIDTH 309 400 "B"
    drawChar $Display::WIDTH 318 400 "O"

    Display::text fb 300 420 PLACEHOLDER "Hello"
}

# random garbage below
# --------------------

if 0 {
sudo apt install git build-essential

# TODO: clone folk

https://forums.libretro.com/t/retroarch-raspberry-pi-4-vulkan-without-x-howto/31164

sudo apt install python3-pip ninja-build
sudo pip3 install meson
sudo pip3 install mako

sudo apt install libdrm-dev
sudo apt install bison flex

git clone -b 20.3 https://gitlab.freedesktop.org/mesa/mesa.git mesa_vulkan
cd mesa_vulkan
meson -Dplatforms= -Dglx=disabled -Dvulkan-drivers=broadcom -Dgallium-drivers=kmsro,v3d,vc4 -Dbuildtype=release build
sudo ninja -C build install
}

if 0 {
git clone --recursive https://github.com/SaschaWillems/Vulkan.git
cd Vulkan

mkdir build
cd build
cmake .. -DUSE_D2D_WSI=ON
}
