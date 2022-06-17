package require critcl

critcl::tcl 8.6
critcl::cflags -Wall -Werror

source "pi/Display.tcl"
source "pi/Camera.tcl"

Display::init
Camera::init

opaquePointerType uint16_t*

critcl::ccode [subst -nocommands -nobackslashes {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>
    
    uint8_t* delayThenCameraCapture(Tcl_Interp* interp) {
        usleep(200000);

        // capture 1 real frame. how do i run the tcl command
        // uargh do i need to pass the interp in
        Tcl_Eval(interp, "yuyv2gray [Camera::frame] $Camera::WIDTH $Camera::HEIGHT");
        uint8_t* image;
        sscanf(Tcl_GetStringResult(interp), "(uint8_t*) 0x%p", &image);
        Tcl_ResetResult(interp);

        printf("capture result %p\n", image);

        return image;
    }
}]

proc eachDisplayPixel {body} {
    return "
        for (int y = 0; y < $Display::HEIGHT; y++) {
            for (int x = 0; x < $Display::WIDTH; x++) {
                uint16_t* it = &fb\[y * $Display::WIDTH + x\]; (void)it;
                $body
            }
        }
    "
}
proc eachCameraPixel {body} {
    return "
        for (int y = 0; y < $Camera::HEIGHT; y++) {
            for (int x = 0; x < $Camera::WIDTH; x++) {
                int i = (y * $Camera::WIDTH) + x; (void)i;
                $body
            }
        }
    "
}

critcl::ccode {
    uint16_t toGrayCode(uint16_t value) {
        return value ^ (value >> 1);
    }
    uint16_t fromGrayCode(uint16_t code) {
        uint16_t mask = code;
        while (mask) {
            mask >>= 1;
            code ^= mask;
        }
        return code;
    }
    int isCloser(uint8_t it, uint8_t this, uint8_t that) {
        return abs(it - this) < abs(it - that);
    }
}

critcl::cproc findDenseCorrespondences {Tcl_Interp* interp uint16_t* fb} void [subst {
    // image the base scene in white
    [eachDisplayPixel { *it = 0xFFFF; }]
    uint8_t* whiteImage = delayThenCameraCapture(interp);

    // image the base scene in black
    [eachDisplayPixel { *it = 0x0000; }]
    uint8_t* blackImage = delayThenCameraCapture(interp);

    // find column correspondences:

    // how many bits do we need in the Gray code?
    int columnBits = ceil(log2f($Display::WIDTH));

    uint16_t* columnCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(uint16_t));

    for (int k = columnBits - 1; k >= 0; k--) {
        [eachDisplayPixel {
            int code = toGrayCode(x);
            *it = ((code >> k) & 1) ? 0xFFFF : 0x0000;
        }]
        uint8_t* codeImage = delayThenCameraCapture(interp);

        [eachDisplayPixel {
            int code = toGrayCode(x);
            *it = ((code >> k) & 1) ? 0x0000 : 0xFFFF;
        }]
        uint8_t* invertedCodeImage = delayThenCameraCapture(interp);

        // scan camera image, add to the correspondence for each pixel
        [eachCameraPixel {
            int bit;
            if (isCloser(codeImage[i], whiteImage[i], blackImage[i]) &&
                isCloser(invertedCodeImage[i], blackImage[i], whiteImage[i])) {
                bit = 1;
            } else if (isCloser(codeImage[i], blackImage[i], whiteImage[i]) &&
                       isCloser(invertedCodeImage[i], whiteImage[i], blackImage[i])) {
                bit = 0;
            } else {
                columnCorr[i] = 0xFFFF; // unable to correspond
                continue;
            }
            columnCorr[i] = (columnCorr[i] << 1) | bit;
        }]

        free(codeImage);
        free(invertedCodeImage);
    }

    // FIXME: convert column correspondences out of Gray code

    // display column correspondences directly. just for fun
    [eachCameraPixel [subst -nocommands -nobackslashes {
        fb[(y * $Display::WIDTH) + x] = columnCorr[i];
    }]]
    
    // FIXME: find row correspondences
}]

puts "camera: $Camera::camera"

findDenseCorrespondences $Display::fb
