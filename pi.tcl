# Wish "/dev/fb0" shows a rectangle with x 0 y
# "<window UUID>" wishes "/dev/fb0" shows a rectangle with x 0 y 0
# (I want to invoke that from a window on my laptop which has a UUID.)

namespace eval Display {
    # TODO: use Vulkan (-:
    variable fb [open "/dev/fb0" w]
    fconfigure $fb -translation binary

    variable WIDTH
    variable HEIGHT
    regexp {mode "(\d+)x(\d+)"} [exec fbset] -> WIDTH HEIGHT

    variable black [binary format b16 [join {00000 000000 00000} ""]]
    variable blue  [binary format b16 [join {11111 000000 00000} ""]]
    variable green [binary format b16 [join {00000 111111 00000} ""]]
    variable red   [binary format b16 [join {00000 000000 11111} ""]]

    proc fillRect {fb x0 y0 x1 y1 color} {
        for {set y $y0} {$y < $y1} {incr y} {
            seek $Display::fb [expr (($y * $Display::WIDTH) + $x0) * 2]
            for {set x $x0} {$x < $x1} {incr x} {
                puts -nonewline $Display::fb $color
            }
        }
    }
    proc fillScreen {fb color} {
        fillRect $fb 0 0 $Display::WIDTH $Display::HEIGHT $color
    }

    proc text {fb x y fontSize text} {
        
    }
}

proc TestStep {} {
    Step {
        Display::fillScreen $Display::fb $Display::green
        Wish $Display::fb shows a rectangle with x 150 y 50 width 30 height 40 fill $Display::blue

        # clear the screen3
    }
}

after 0 TestStep
vwait forever

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
