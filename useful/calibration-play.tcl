package require critcl

critcl::tcl 8.6
critcl::cflags -Wall -Werror

source "pi/Display.tcl"
source "pi/Camera.tcl"

Display::init
Camera::init

opaquePointerType uint16_t*

critcl::ccode {
    uint8_t* delayThenCapture() {
        usleep(20000);

        // capture 1 real frame. how do i run the tcl command
        // uargh do i need to pass the interp in
        
        return;
    }
}

proc eachDisplayPixel {body} {
    return "
        for (int y = 0; y < $Display::HEIGHT; y++) {
            for (int x = 0; x < $Display::WIDTH; x++) {
                uint16_t* it = &fb\[y * $Display::WIDTH + x\];
                $body
            }
        }
    "
}
proc eachCameraPixel {body} {
    return "
        for (int y = 0; y < $Camera::HEIGHT; y++) {
            for (int x = 0; x < $Camera::WIDTH; x++) {
                $body
            }
        }
    "
}

critcl::ccode {
    uint16_t toGrayCode(uint16_t value) {
        return value;
    }
    uint16_t fromGrayCode(uint16_t code) {
        return code;
    }
}

proc eachCameraPixel {image body} {
    return body
}

critcl::cproc buildDenseCorrespondences {Tcl_Interp* interp uint16_t* fb} void [subst {
    // image the base scene in white
    [eachDisplayPixel { *it = 0xFFFF; }]
    uint8_t* whiteImage = delayThenCapture();

    // image the base scene in black
    [eachDisplayPixel { *it = 0x0000; }]
    uint8_t* blackImage = delayThenCapture();

    // build column correspondences:

    // how many bits do we need in the Gray code?
    int columnBits = ceil(log2f($Display::WIDTH));

    uint16_t* columnCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(uint16_t));

    for (int k = 0; k < columnBits; k++) {
        [eachDisplayPixel {
            int code = toGrayCode(x);
            *it = ((code >> k) & 1) ? 0xFFFF : 0x0000;
        }]
        uint8_t* codeImage = delayThenCapture();

        [eachDisplayPixel {
            int code = toGrayCode(x);
            *it = ((code >> k) & 1) ? 0x0000 : 0xFFFF;
        }]
        uint8_t* invertedCodeImage = delayThenCapture();

        // scan camera image, add to the correspondence for each pixel
        [eachCameraPixel {
            int i = (y * $Camera::WIDTH) + x;
            whiteImage[i], blackImage[i], codeImage[i], invertedCodeImage[i];

            columnCorr[i] = (columnCorr[i] << 1) | bit;
        }]
    }

    // TODO: display column correspondences

    // FIXME: build row correspondences
}]

puts "camera: $Camera::camera"

buildDenseCorrespondences $Display::fb
