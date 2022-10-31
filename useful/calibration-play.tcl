package require critcl

critcl::tcl 8.6
critcl::cflags -Wall -Werror
critcl::clibraries [lindex [exec /usr/sbin/ldconfig -p | grep libjpeg] end]
critcl::clean_cache

source "pi/Display.tcl"
source "pi/Camera.tcl"

Display::init
Camera::init 3840 2160

critcl::ccode {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>
}

if {$Display::DEPTH == 16} {
    critcl::ccode {
        typedef uint16_t pixel_t;
        #define PIXEL(r, g, b) \
            (((((r) >> 3) & 0x1F) << 11) | \
             ((((g) >> 2) & 0x3F) << 5) | \
             (((b) >> 3) & 0x1F));
    }
} elseif {$Display::DEPTH == 32} {
    critcl::ccode {
        typedef uint32_t pixel_t;
        #define PIXEL(r, g, b) (((r) << 16) | ((g) << 8) | ((b) << 0))
    }
} else {
    error "calibration-play: Unusable depth $Display::DEPTH"
}

critcl::ccode {
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

        Tcl_Eval(interp, "freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; set rgb [Camera::frame]; set gray [rgbToGray $rgb $Camera::WIDTH $Camera::HEIGHT]; freeImage $rgb; return $gray");
        uint8_t* image;
        sscanf(Tcl_GetStringResult(interp), "(uint8_t*) 0x%p", &image);
        Tcl_ResetResult(interp);

        Tcl_Eval(interp, "set Camera::WIDTH");
        int width; Tcl_GetInt(interp, Tcl_GetStringResult(interp), &width); Tcl_ResetResult(interp);
        Tcl_Eval(interp, "set Camera::HEIGHT");
        int height; Tcl_GetInt(interp, Tcl_GetStringResult(interp), &height); Tcl_ResetResult(interp);

        captureNum++;
        printf("capture result %d (%s): %p (%dx%d)\n", captureNum, description, image, width, height);
        // write capture to jpeg
        char filename[100]; snprintf(filename, 100, "capture%02d-%s.jpg", captureNum, description);
        FILE* out = fopen(filename, "w");
        jpeg(out, image, width, height, 100);
        fclose(out);

        return image;
    }
}

proc eachDisplayPixel {body} {
    return "
        for (int y = 0; y < $Display::HEIGHT; y++) {
            for (int x = 0; x < $Display::WIDTH; x++) {
                pixel_t* it = &fb\[y * $Display::WIDTH + x\]; (void)it;
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
    #define BLACK PIXEL(0, 0, 0)
    #define WHITE PIXEL(255, 255, 255)

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
        pixel_t* columnCorr;
        pixel_t* rowCorr;
    } dense_t;
}
opaquePointerType dense_t*

# returns dense correspondence from camera space -> projector space
critcl::cproc findDenseCorrespondence {Tcl_Interp* interp pixel_t* fb} dense_t* [subst -nobackslashes {
    // image the base scene in white
    [eachDisplayPixel { *it = WHITE; }]
    uint8_t* whiteImage = delayThenCameraCapture(interp, "whiteImage");

    // image the base scene in black
    [eachDisplayPixel { *it = BLACK; }]
    uint8_t* blackImage = delayThenCameraCapture(interp, "blackImage");

    // find column correspondences:
    pixel_t* columnCorr;
    {
        // how many bits do we need in the Gray code?
        int columnBits = ceil(log2f($Display::WIDTH));

        columnCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(pixel_t));

        for (int k = columnBits - 1; k >= 0; k--) {
            [eachDisplayPixel {
                int code = toGrayCode(x);
                *it = ((code >> k) & 1) ? WHITE : BLACK;
            }]
            uint8_t* codeImage = delayThenCameraCapture(interp, "columnCodeImage");

            [eachDisplayPixel {
                int code = toGrayCode(x);
                *it = ((code >> k) & 1) ? BLACK : WHITE;
            }]
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "columnInvertedCodeImage");

            // scan camera image, add to the correspondence for each pixel
            [eachCameraPixel {
                if (columnCorr[i] == WHITE) continue;

                int bit;
                if (isCloser(codeImage[i], whiteImage[i], blackImage[i])) {
                    bit = 1;
                } else if (isCloser(codeImage[i], blackImage[i], whiteImage[i])) {
                    bit = 0;
                } else {
                    if (k == 0 || k == 1 || k == 2) {
                        bit = 0;
                    } else {
                        columnCorr[i] = WHITE; // unable to correspond
                        continue;
                    }
                }
                columnCorr[i] = (columnCorr[i] << 1) | bit;
            }]

            free(codeImage);
            free(invertedCodeImage);
        }

        // convert column correspondences out of Gray code
        [eachCameraPixel {
            if (columnCorr[i] != WHITE) {
                columnCorr[i] = fromGrayCode(columnCorr[i]);
            }
        }]
    }
    
    // find row correspondences:
    pixel_t* rowCorr;
    {
        // how many bits do we need in the Gray code?
        int rowBits = ceil(log2f($Display::WIDTH));

        rowCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(pixel_t));

        for (int k = rowBits - 1; k >= 0; k--) {
            [eachDisplayPixel {
                int code = toGrayCode(y);
                *it = ((code >> k) & 1) ? WHITE : BLACK;
            }]
            uint8_t* codeImage = delayThenCameraCapture(interp, "rowCodeImage");

            [eachDisplayPixel {
                int code = toGrayCode(y);
                *it = ((code >> k) & 1) ? BLACK : WHITE;
            }]
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "rowInvertedCodeImage");

            // scan camera image, add to the correspondence for each pixel
            [eachCameraPixel {
                if (rowCorr[i] == WHITE) continue;
                
                int bit;
                if (isCloser(codeImage[i], whiteImage[i], blackImage[i])) {
                    bit = 1;
                } else if (isCloser(codeImage[i], blackImage[i], whiteImage[i])) {
                    bit = 0;
                } else {
                    if (k == 0 || k == 1 || k == 2) {
                        bit = 0;
                    } else {
                        rowCorr[i] = WHITE; // unable to correspond
                        continue;
                    }
                }
                rowCorr[i] = (rowCorr[i] << 1) | bit;
            }]

            free(codeImage);
            free(invertedCodeImage);
        }

        // convert row correspondences out of Gray code
        [eachCameraPixel {
            if (rowCorr[i] != WHITE) {
                rowCorr[i] = fromGrayCode(rowCorr[i]);
            }
        }]
    }

    dense_t* dense = malloc(sizeof(dense_t));
    dense->columnCorr = columnCorr;
    dense->rowCorr = rowCorr;
    return dense;
}]

critcl::cproc displayDenseCorrespondence {Tcl_Interp* interp pixel_t* fb dense_t* dense} void [subst -nobackslashes {
    // image the base scene in black for reference
    [eachDisplayPixel { *it = BLACK; }]
    uint8_t* blackImage = delayThenCameraCapture(interp, "displayBlackImage");

    // display dense correspondence directly. just for fun
    [eachCameraPixel [subst -nocommands -nobackslashes {
        uint8_t pix = blackImage[i];
        fb[(y * $Display::WIDTH) + x] = PIXEL(pix, pix, pix);
        continue;

        if (dense->columnCorr[i] == WHITE && dense->rowCorr[i] == WHITE) {
            uint8_t pix = blackImage[i];
            fb[(y * $Display::WIDTH) + x] = PIXEL(pix, pix, pix);
        } else if (dense->columnCorr[i] == WHITE && dense->rowCorr[i] != WHITE) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(255, 0, 0); // red: row-only match
        } else if (dense->columnCorr[i] != WHITE && dense->rowCorr[i] == WHITE) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(0, 0, 255); // blue: column-only match
        } else if (dense->columnCorr[i] != WHITE && dense->rowCorr[i] != WHITE) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(0, 255, 0); // green: double match
        }
    }]]
}]

critcl::cproc findNearbyCorrespondences {dense_t* dense int cx int cy int size} Tcl_Obj*0 [subst -nobackslashes -nocommands {
    // find correspondences inside the tag
    Tcl_Obj* correspondences[2000];
    int correspondenceCount = 0;

    for (int x = cx - size/2; x < cx + size/2; x++) {
        for (int y = cy - size/2; y < cy + size/2; y++) {
            int i = (y * $Camera::WIDTH) + x;
            if (dense->columnCorr[i] != WHITE && dense->rowCorr[i] != WHITE) {
                correspondences[correspondenceCount++] = Tcl_ObjPrintf("%d %d %d %d", x, y, dense->columnCorr[i], dense->rowCorr[i]);
            }
        }
    }
    printf("correspondenceCount: %d\n", correspondenceCount);

    return Tcl_NewListObj(correspondenceCount, correspondences);
}]

puts "camera: $Camera::camera"

set dense [findDenseCorrespondence $Display::fb]
puts "dense: $dense"
displayDenseCorrespondence $Display::fb $dense

AprilTags::init

set frame [Camera::frame]
set grayFrame [rgbToGray $frame $Camera::WIDTH $Camera::HEIGHT]
freeImage $frame
set tags [AprilTags::detect $grayFrame]
freeImage $grayFrame
puts "tags: $tags"

foreach tag $tags {
    # these are in camera space
    set cx [expr int([lindex [dict get $tag center] 0])]
    set cy [expr int([lindex [dict get $tag center] 1])]
    set size [expr int([dict get $tag size])]

    puts "nearby: [findNearbyCorrespondences $dense $cx $cy $size]"
}
