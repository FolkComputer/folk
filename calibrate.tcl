source "lib/c.tcl"
c loadlib [lindex [exec /usr/sbin/ldconfig -p | grep libpng] end]

exec sudo systemctl stop folk
catch {
    exec v4l2-ctl --set-ctrl=focus_auto=0
    exec v4l2-ctl --set-ctrl=focus_absolute=0
}

set cc [c create]

source "pi/Display.tcl"
source "pi/Camera.tcl"

Display::init
# FIXME: adapt to camera spec
# Camera::init 3840 2160
Camera::init 1920 1080

$cc code {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>
}

if {$Display::DEPTH == 16} {
    $cc code {
        typedef uint16_t pixel_t;
        #define PIXEL(r, g, b) \
            (((((r) >> 3) & 0x1F) << 11) | \
             ((((g) >> 2) & 0x3F) << 5) | \
             (((b) >> 3) & 0x1F))
    }
} elseif {$Display::DEPTH == 32} {
    $cc code {
        typedef uint32_t pixel_t;
        #define PIXEL(r, g, b) (((r) << 16) | ((g) << 8) | ((b) << 0))
    }
} else {
    error "calibrate: Unusable depth $Display::DEPTH"
}

$cc code {
    #include <png.h>

  void rgb_png(FILE* dest, uint8_t* rgb, uint32_t width, uint32_t height, int quality)
  {
      png_bytep* row_pointers = (png_bytep*) calloc(height, sizeof(png_bytep));
      for (size_t i = 0; i < height; i++) {
          row_pointers[i] = calloc(4 * width, sizeof(png_byte));
          for (size_t j = 0; j < width; j++) {
              row_pointers[i][j * 4 + 0] = rgb[(i * width + j) * 3 + 0];
              row_pointers[i][j * 4 + 1] = rgb[(i * width + j) * 3 + 1];
              row_pointers[i][j * 4 + 2] = rgb[(i * width + j) * 3 + 2];
              row_pointers[i][j * 4 + 3] = 255;
          }
      }

      png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
      if (!png_ptr) { exit(1); }

      png_infop info_ptr = png_create_info_struct(png_ptr);
      if (!info_ptr) { exit(1); }

      if (setjmp(png_jmpbuf(png_ptr))) { exit(2); }

      png_init_io(png_ptr, dest);
      png_set_IHDR(png_ptr, info_ptr, width, height,
                   8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_BASE, PNG_FILTER_TYPE_BASE);
      png_write_info(png_ptr, info_ptr);
      png_write_image(png_ptr, row_pointers);
      png_write_end(png_ptr, NULL);

      png_destroy_write_struct(&png_ptr, &info_ptr);
      for (size_t i = 0; i < height; i++) {
          free(row_pointers[i]);
      }
      free(row_pointers);
  }

  // a grayscale image
  void png(FILE* dest, uint8_t* grey, uint32_t width, uint32_t height, int quality)
  {
      uint8_t* rgb = calloc(width*3, height);
      for (int i = 0; i < width * height; i++) {
          rgb[i*3] = grey[i];
          rgb[i*3+1] = grey[i];
          rgb[i*3+2] = grey[i];
      }
      
      rgb_png(dest, rgb, width, height, quality);
      free(rgb);
  }


    int captureNum = 0;
    uint8_t* delayThenCameraCapture(Tcl_Interp* interp, const char* description) {
        usleep(100000);

        Tcl_Eval(interp, "freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; freeImage [Camera::frame]; set rgb [Camera::frame]; set gray [rgbToGray $rgb]; freeImage $rgb; dict get $gray data");
        uint8_t* image;
        sscanf(Tcl_GetStringResult(interp), "0x%p", &image);
        Tcl_ResetResult(interp);

        Tcl_Eval(interp, "set Camera::WIDTH");
        int width; Tcl_GetInt(interp, Tcl_GetStringResult(interp), &width); Tcl_ResetResult(interp);
        Tcl_Eval(interp, "set Camera::HEIGHT");
        int height; Tcl_GetInt(interp, Tcl_GetStringResult(interp), &height); Tcl_ResetResult(interp);

        captureNum++;
        printf("capture result %d (%s): %p (%dx%d)\n", captureNum, description, image, width, height);
        // write capture to png
        char filename[100]; snprintf(filename, 100, "capture%02d-%s.png", captureNum, description);
        FILE* out = fopen(filename, "w");
        png(out, image, width, height, 100);
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

$cc code {
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
    int isCloser(uint8_t it, uint8_t itInv, uint8_t this, uint8_t that) {
        int thisError = abs(it - this) + abs(itInv - that);
        int thatError = abs(it - that) + abs(itInv - this);
        return thisError < thatError;
    }

    typedef struct {
        uint16_t* columnCorr;
        uint16_t* rowCorr;
    } dense_t;
}

# returns dense correspondence from camera space -> projector space
$cc proc findDenseCorrespondence {Tcl_Interp* interp pixel_t* fb} dense_t* [subst -nobackslashes {
    // image the base scene in white
    [eachDisplayPixel { *it = WHITE; }]
    uint8_t* whiteImage = delayThenCameraCapture(interp, "whiteImage");

    // image the base scene in black
    [eachDisplayPixel { *it = BLACK; }]
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
                if (columnCorr[i] == 0xFFFF) continue;

                int bit;
                if (isCloser(codeImage[i], invertedCodeImage[i], whiteImage[i], blackImage[i])) {
                    bit = 1;
                } else if (isCloser(codeImage[i], invertedCodeImage[i], blackImage[i], whiteImage[i])) {
                    bit = 0;
                } else {
                    if (k == 0) { // ignore least significant bit
                        bit = 0;
                    } else {
                        columnCorr[i] = 0xFFFF; // unable to correspond
                        continue;
                    }
                }
                columnCorr[i] = (columnCorr[i] << 1) | bit;
            }]

            ckfree(codeImage);
            ckfree(invertedCodeImage);
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
                if (rowCorr[i] == 0xFFFF) continue;
                
                int bit;
                if (isCloser(codeImage[i], invertedCodeImage[i], whiteImage[i], blackImage[i])) {
                    bit = 1;
                } else if (isCloser(codeImage[i], invertedCodeImage[i], blackImage[i], whiteImage[i])) {
                    bit = 0;
                } else {
                    if (k == 0) {
                        bit = 0;
                    } else {
                        rowCorr[i] = 0xFFFF; // unable to correspond
                        continue;
                    }
                }
                rowCorr[i] = (rowCorr[i] << 1) | bit;
            }]

            ckfree(codeImage);
            ckfree(invertedCodeImage);
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

$cc proc remap {int x int x0 int x1 int y0 int y1} int {
  return y0 + (x - x0) * (y1 - y0) / (x1 - x0);
}


$cc proc cleanCorrespondense {uint16_t* corr uint16_t* cleanCorr} void [csubst {
  uint32_t width = $Camera::WIDTH;
  uint32_t height = $Camera::HEIGHT;

  int startOfLake = -1;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      uint16_t v = corr[i];
      if (startOfLake == -1) {
        if (v == 0xFFFF) {
          // we're in the beginning of our image
          cleanCorr[i] = 0xFFFF; // keep the sentinel for now
        } else {
          startOfLake = i;
          cleanCorr[i] = v;
        }
      } else {
        // we do have a start of the lake
        // find the next one
        if (v == 0xFFFF) {
          // write a sentinel just in case we never hit the end of a lake
          cleanCorr[i] = 0xFFFF;
        } else {
          // write the valid data we found first
          cleanCorr[i] = v;

          for (int j = startOfLake+1; j < i; j++) {
            float t = (float)(j - startOfLake) / (float)(i - startOfLake);
            uint16_t startOfLakeValue = corr[startOfLake];
            cleanCorr[j] = startOfLakeValue + t * (v - startOfLakeValue);
          }

          startOfLake = i;
        }
      }
    }
  }
}]

$cc proc cleanDenseCorrespondense {dense_t* dense} dense_t* [csubst {
  uint32_t width = $Camera::WIDTH;
  uint32_t height = $Camera::HEIGHT;

  dense_t* cleanDense = malloc(sizeof(dense_t));
  cleanDense->rowCorr = calloc(width*height, sizeof(uint16_t));
  cleanDense->columnCorr = calloc(width*height, sizeof(uint16_t));

  cleanCorrespondense(dense->rowCorr, cleanDense->rowCorr);
  cleanCorrespondense(dense->columnCorr, cleanDense->columnCorr);

  return cleanDense;
}]
$cc proc writeDenseCorrespondenseToDisk {dense_t* dense char* filename} void [csubst {
  FILE* out = fopen(filename, "w");

  uint32_t width = $Camera::WIDTH;
  uint32_t height = $Camera::HEIGHT;

  uint8_t* rgb = calloc(width * 3, height);

  int rowCorrMin = 32768;
  int rowCorrMax = -32768; 
  int columnCorrMin = 32768;
  int columnCorrMax = -32768; 

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      int v = dense->columnCorr[i];
      if (v == 0xFFFF) {
        // do nothing
      } else if (v < columnCorrMin) {
        columnCorrMin = v;
      } else if (v > columnCorrMax) {
        columnCorrMax = v;
      }
    }
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      int v = dense->rowCorr[i];
      if (v == 0xFFFF) {
        // do nothing
      } else if (v < rowCorrMin) {
        rowCorrMin = v;
      } else if (v > rowCorrMax) {
        rowCorrMax = v;
      }
    }
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      rgb[i*3] = (uint8_t)remap(dense->columnCorr[i], columnCorrMin, columnCorrMax, 0, 255);
      rgb[i*3 + 1] = (uint8_t)remap(dense->rowCorr[i], rowCorrMin, rowCorrMax, 0, 255);
      rgb[i*3 + 2] = 0;
    }
  }

    printf("\n\nrowCorrMin: %d\nrowCorrMax: %d\ncolumnCorrMin: %d\ncolumnCorrMax: %d\n\n",
           rowCorrMin, rowCorrMax, columnCorrMin, columnCorrMax);

  rgb_png(out, rgb, width, height, 100);
  fclose(out);
}]

$cc proc serializeDenseCorrespondence {dense_t* dense char* filename} void [csubst {
    uint32_t width = $Camera::WIDTH;
    uint32_t height = $Camera::HEIGHT;

    FILE* out = fopen(filename, "w");
    fwrite(&width, sizeof(uint32_t), 1, out);
    fwrite(&height, sizeof(uint32_t), 1, out);
    fwrite(dense->columnCorr, sizeof(uint16_t), width*height, out);
    fwrite(dense->rowCorr, sizeof(uint16_t), width*height, out);
    fclose(out);
}]
    
$cc proc displayDenseCorrespondence {Tcl_Interp* interp pixel_t* fb dense_t* dense} void [csubst {
    // image the base scene in black for reference
    $[eachDisplayPixel { *it = BLACK; }]
    uint8_t* blackImage = delayThenCameraCapture(interp, "displayBlackImage");

    char* filename = "/tmp/dense-$[clock format [clock seconds] -format "%H.%M.%S" ].png";
    writeDenseCorrespondenseToDisk(dense, filename);
    dense_t* cleanDense = cleanDenseCorrespondense(dense);
    filename = "/tmp/clean-dense-$[clock format [clock seconds] -format "%H.%M.%S" ].png";
    writeDenseCorrespondenseToDisk(cleanDense, filename);

    serializeDenseCorrespondence(cleanDense, "/home/folk/generated-clean-dense.dense");

    // display dense correspondence directly. just for fun
    $[eachCameraPixel [subst -nocommands -nobackslashes {
        if (dense->columnCorr[i] == 0 && dense->rowCorr[i] == 0) { // ???
            fb[(y * $Display::WIDTH) + x] = PIXEL(255, 255, 0);
        } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            uint8_t pix = blackImage[i];
            fb[(y * $Display::WIDTH) + x] = PIXEL(pix, pix, pix);
        } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(255, 0, 0); // red: row-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(0, 0, 255); // blue: column-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            fb[(y * $Display::WIDTH) + x] = PIXEL(0, 255, 0); // green: double match
        }
    }]]
}]

$cc proc findNearbyCorrespondences {dense_t* dense int cx int cy int size} Tcl_Obj* [subst -nobackslashes -nocommands {
    // find correspondences inside the tag
    Tcl_Obj* correspondences[size*size];
    int correspondenceCount = 0;

    for (int x = cx; x < cx + size; x++) {
        for (int y = cy; y < cy + size; y++) {
            int i = (y * $Camera::WIDTH) + x;
            if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
                correspondences[correspondenceCount++] = Tcl_ObjPrintf("%f %f %d %d", (float)x, (float)y, dense->columnCorr[i], dense->rowCorr[i]);
            }
        }
    }
    printf("correspondenceCount: %d\n", correspondenceCount);

    // Tcl_Incr
    return Tcl_NewListObj(correspondenceCount, correspondences);
}]

$cc compile

puts "camera: $Camera::camera"

set dense [findDenseCorrespondence $Display::fb]
puts "dense: $dense"
displayDenseCorrespondence $Display::fb $dense

AprilTags::init

set grayFrame [Camera::grayFrame]
set tags [AprilTags::detect $grayFrame]
freeImage $grayFrame

puts ""
set keyCorrespondences [list]
foreach tag $tags {
    puts ""
    puts "for tag $tag:"
    
    # these are in camera space
    set cx [lindex [dict get $tag center] 0]
    set cy [lindex [dict get $tag center] 1]

    set keypoints [list [list $cx $cy] {*}[dict get $tag corners]]
    puts "keypoints: $keypoints"
    set correspondences [list]
    foreach keypoint $keypoints {
        lassign $keypoint x y
        set nearby [findNearbyCorrespondences $dense [expr {int($x)}] [expr {int($y)}] 3]
        if {[llength $nearby] > 0} {
            lappend correspondences [lindex $nearby 0]
        }
    }

    if {[llength $correspondences] == 0} { continue }
    puts "nearby: [llength $correspondences] correspondences: $correspondences"
    puts ""

    lassign [lindex $correspondences 0] _ _ px py
    lassign [lindex $correspondences end] _ _ px1 py1
    puts "$px $py $px1 $py1"
    Display::fillTriangle \
        [list $px $py] \
        [list $px1 $py1] \
        [list $px $py1] \
        red
    set id [dict get $tag id]
    Display::text fb $px $py 10 "$id" 0
    Display::text fb $px1 $py1 10 "$id'" 0
    
    lappend keyCorrespondences [lindex $correspondences 0]
}
# lappend keyCorrespondences [lindex $correspondences end]
set keyCorrespondences [lrange $keyCorrespondences 0 3] ;# can only use 4 points

puts "key correspondences: $keyCorrespondences"

set fd [open "/home/folk/generated-calibration.tcl" w]
puts $fd [subst {
    namespace eval generatedCalibration {
        variable cameraWidth $Camera::WIDTH
        variable cameraHeight $Camera::HEIGHT
        variable displayWidth $Display::WIDTH
        variable displayHeight $Display::HEIGHT
        variable points {$keyCorrespondences}
    }
}]
close $fd

Display::commit
# exec sudo systemctl start folk &
