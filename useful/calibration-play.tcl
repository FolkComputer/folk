package require critcl

critcl::tcl 8.6
critcl::cflags -Wall -Werror
critcl::clibraries /usr/lib/arm-linux-gnueabihf/libjpeg.so.62

source "pi/Display.tcl"
source "pi/Camera.tcl"

Display::init
Camera::init

opaquePointerType uint16_t*

critcl::ccode {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>

    #include <jpeglib.h>

    void 
jpeg(FILE* dest, uint8_t* rgb, uint32_t width, uint32_t height, int quality)
{
  JSAMPARRAY image;
  image = calloc(height, sizeof (JSAMPROW));
  for (size_t i = 0; i < height; i++) {
    image[i] = calloc(width * 3, sizeof (JSAMPLE));
    for (size_t j = 0; j < width; j++) {
      image[i][j * 3 + 0] = rgb[(i * width + j)];
      image[i][j * 3 + 1] = rgb[(i * width + j)];
      image[i][j * 3 + 2] = rgb[(i * width + j)];
    }
  }
  
  struct jpeg_compress_struct compress;
  struct jpeg_error_mgr error;
  compress.err = jpeg_std_error(&error);
  jpeg_create_compress(&compress);
  jpeg_stdio_dest(&compress, dest);
  
  compress.image_width = width;
  compress.image_height = height;
  compress.input_components = 3;
  compress.in_color_space = JCS_RGB;
  jpeg_set_defaults(&compress);
  jpeg_set_quality(&compress, quality, TRUE);
  jpeg_start_compress(&compress, TRUE);
  jpeg_write_scanlines(&compress, image, height);
  jpeg_finish_compress(&compress);
  jpeg_destroy_compress(&compress);

  for (size_t i = 0; i < height; i++) {
    free(image[i]);
  }
  free(image);
}

    int captureNum = 0;
    uint8_t* delayThenCameraCapture(Tcl_Interp* interp, const char* description) {
        usleep(100000);

        Tcl_Eval(interp, "Camera::frame; Camera::frame; Camera::frame; Camera::frame; yuyv2gray [Camera::frame] $Camera::WIDTH $Camera::HEIGHT");
        uint8_t* image;
        sscanf(Tcl_GetStringResult(interp), "(uint8_t*) 0x%p", &image);
        Tcl_ResetResult(interp);

        captureNum++;
        printf("capture result %d (%s): %p\n", captureNum, description, image);
        // write capture to jpeg
        char filename[100]; snprintf(filename, 100, "capture%02d-%s.jpg", captureNum, description);
        FILE* out = fopen(filename, "w");
        jpeg(out, image, 1280, 720, 100);
        fclose(out);

        return image;
    }
}

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

    typedef struct {
        uint16_t* columnCorr;
        uint16_t* rowCorr;
    } dense_t;
}
opaquePointerType dense_t*

# returns dense correspondence from camera space -> projector space
critcl::cproc findDenseCorrespondence {Tcl_Interp* interp uint16_t* fb} dense_t* [subst -nobackslashes {
    // image the base scene in white
    [eachDisplayPixel { *it = 0xFFFF; }]
    uint8_t* whiteImage = delayThenCameraCapture(interp, "whiteImage");

    // image the base scene in black
    [eachDisplayPixel { *it = 0x0000; }]
    uint8_t* blackImage = delayThenCameraCapture(interp, "blackImage");

    // find column correspondences:
    uint16_t* columnCorr;
    {
        // how many bits do we need in the Gray code?
        int columnBits = ceil(log2f($Display::WIDTH));

        columnCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(uint16_t));

        for (int k = columnBits - 1; k >= 0; k--) {
            [eachDisplayPixel {
                int code = toGrayCode(x);
                *it = ((code >> k) & 1) ? 0xFFFF : 0x0000;
            }]
            uint8_t* codeImage = delayThenCameraCapture(interp, "columnCodeImage");

            [eachDisplayPixel {
                int code = toGrayCode(x);
                *it = ((code >> k) & 1) ? 0x0000 : 0xFFFF;
            }]
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "columnInvertedCodeImage");

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

        // convert column correspondences out of Gray code
        [eachCameraPixel {
            if (columnCorr[i] != 0xFFFF) {
                columnCorr[i] = fromGrayCode(columnCorr[i]);
            }
        }]
    }
    
    // find row correspondences:
    uint16_t* rowCorr;
    {
        // how many bits do we need in the Gray code?
        int rowBits = ceil(log2f($Display::WIDTH));

        rowCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(uint16_t));

        for (int k = rowBits - 1; k >= 0; k--) {
            [eachDisplayPixel {
                int code = toGrayCode(y);
                *it = ((code >> k) & 1) ? 0xFFFF : 0x0000;
            }]
            uint8_t* codeImage = delayThenCameraCapture(interp, "rowCodeImage");

            [eachDisplayPixel {
                int code = toGrayCode(y);
                *it = ((code >> k) & 1) ? 0x0000 : 0xFFFF;
            }]
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "rowInvertedCodeImage");

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
                    rowCorr[i] = 0xFFFF; // unable to correspond
                    continue;
                }
                rowCorr[i] = (rowCorr[i] << 1) | bit;
            }]

            free(codeImage);
            free(invertedCodeImage);
        }

        // convert row correspondences out of Gray code
        [eachCameraPixel {
            if (rowCorr[i] != 0xFFFF) {
                rowCorr[i] = fromGrayCode(rowCorr[i]);
            }
        }]
    }

    dense_t* dense = malloc(sizeof(dense_t));
    dense->columnCorr = columnCorr;
    dense->rowCorr = rowCorr;
    return dense;
}]

critcl::cproc displayDenseCorrespondence {Tcl_Interp* interp uint16_t* fb dense_t* dense} void [subst -nobackslashes {
    // image the base scene in black for reference
    [eachDisplayPixel { *it = 0x0000; }]
    uint8_t* blackImage = delayThenCameraCapture(interp, "displayBlackImage");

    // display dense correspondence directly. just for fun
    [eachCameraPixel [subst -nocommands -nobackslashes {
        if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            uint8_t pix = blackImage[i];
            fb[(y * $Display::WIDTH) + x] = (((pix >> 3) & 0x1F) << 11) |
               (((pix >> 2) & 0x3F) << 5) |
               ((pix >> 3) & 0x1F);
        } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = 0x00F0; // row-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = 0x0F00; // column-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = 0xF000; // red -- double match
        }
    }]]
}]

critcl::cproc findNearbyCorrespondences {dense_t* dense int cx int cy int size} Tcl_Obj*0 {
    // find correspondences inside the tag
    Tcl_Obj* correspondences[2000];
    int correspondenceCount = 0;

    for (int x = cx - size/2; x < cx + size/2; x++) {
        for (int y = cy - size/2; y < cy + size/2; y++) {
            int i = (y * 1280) + x;
            if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
                correspondences[correspondenceCount++] = Tcl_ObjPrintf("%d %d %d %d", x, y, dense->columnCorr[i], dense->rowCorr[i]);
            }
        }
    }
    printf("correspondenceCount: %d\n", correspondenceCount);

    return Tcl_NewListObj(correspondenceCount, correspondences);
}

puts "camera: $Camera::camera"

set dense [findDenseCorrespondence $Display::fb]
puts "dense: $dense"
displayDenseCorrespondence $Display::fb $dense

AprilTags::init

set frame [Camera::frame]
set grayFrame [yuyv2gray $frame $Camera::WIDTH $Camera::HEIGHT]
set tags [AprilTags::detect $grayFrame]
freeGray $grayFrame
puts "tags: $tags"

foreach tag $tags {
    # these are in camera space
    set cx [expr int([lindex [dict get $tag center] 0])]
    set cy [expr int([lindex [dict get $tag center] 1])]
    set size [expr int([dict get $tag size])]

    puts "nearby: [findNearbyCorrespondences $dense $cx $cy $size]"
}
