source "lib/language.tcl"
source "lib/c.tcl"

exec sudo systemctl stop folk
catch {
    exec v4l2-ctl --set-ctrl=focus_auto=0
    exec v4l2-ctl --set-ctrl=focus_absolute=0
}

source "pi/Camera.tcl"
source "pi/AprilTags.tcl"

# FIXME: These are hacks/stubs so we can just load display.folk
# without needing any other Folk stuff.
set ::isLaptop false
set ::thisProcess [pid]
interp alias {} Step {} break
proc Commit {args} {}
proc When {args} {}
proc Retract {args} {}
proc Wish {args} {}
proc On {_process arg} { eval $arg }
namespace eval Statements { proc findMatches {args} { return [list] } }
source "lib/math.tcl"
source "virtual-programs/display.folk"

# FIXME: adapt to camera spec
# Camera::init 3840 2160
Camera::init 1920 1080
set tagfamily "tagStandard52h13"


set cc [c create]
$cc cflags -L[lindex [exec /usr/sbin/ldconfig -p | grep libjpeg] end]

$cc code {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>
}

$cc code {
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

        Tcl_Eval(interp, "Camera::freeImage [Camera::frame]; Camera::freeImage [Camera::frame]; Camera::freeImage [Camera::frame]; Camera::freeImage [Camera::frame]; Camera::freeImage [Camera::frame]; set rgb [Camera::frame]; set gray [Camera::rgbToGray $rgb]; Camera::freeImage $rgb; dict get $gray data");
        uint8_t* image;
        sscanf(Tcl_GetStringResult(interp), "0x%p", &image);
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

set ::clearScreen [Gpu::pipeline {vec4 color} {
    vec2 vertices[4] = vec2[4](vec2(0, 0), vec2(_resolution.x, 0), vec2(0, _resolution.y), _resolution);
    return vertices[gl_VertexIndex];
} {
    return color;
}]

set ::columnGrayCode [Gpu::pipeline {int k int invert} {
    vec2 vertices[4] = vec2[4](vec2(0, 0), vec2(_resolution.x, 0), vec2(0, _resolution.y), _resolution);
    return vertices[gl_VertexIndex];
} {
    int column = int(gl_FragCoord.x);
    int code = column ^ (column >> 1);
    if (invert == 1) {
        return ((code >> k) & 1) == 1 ? vec4(0, 0, 0, 1) : vec4(1, 1, 1, 1);
    } else {
        return ((code >> k) & 1) == 1 ? vec4(1, 1, 1, 1) : vec4(0, 0, 0, 1);
    }
}]

set ::rowGrayCode [Gpu::pipeline {int k int invert} {
    vec2 vertices[4] = vec2[4](vec2(0, 0), vec2(_resolution.x, 0), vec2(0, _resolution.y), _resolution);
    return vertices[gl_VertexIndex];
} {
    int row = int(gl_FragCoord.y);
    int code = row ^ (row >> 1);
    if (invert == 1) {
        return ((code >> k) & 1) == 1 ? vec4(0, 0, 0, 1) : vec4(1, 1, 1, 1);
    } else {
        return ((code >> k) & 1) == 1 ? vec4(1, 1, 1, 1) : vec4(0, 0, 0, 1);
    }
}]

# returns dense correspondence from camera space -> projector space
$cc code {
    #define DRAW(...) do { Tcl_Eval(interp, "Gpu::drawStart"); Tcl_EvalObjEx(interp, Tcl_ObjPrintf(__VA_ARGS__), 0); Tcl_Eval(interp, "Gpu::drawEnd"); } while (0)
}
$cc proc findDenseCorrespondence {Tcl_Interp* interp} dense_t* {
    // image the base scene in white
    DRAW("Gpu::draw {$clearScreen} {1 1 1 1}");
    uint8_t* whiteImage = delayThenCameraCapture(interp, "whiteImage");

    // image the base scene in black
    DRAW("Gpu::draw {$clearScreen} {0 0 0 1}");
    uint8_t* blackImage = delayThenCameraCapture(interp, "blackImage");

    // find column correspondences:
    uint16_t* columnCorr;
    {
        // how many bits do we need in the Gray code?
        int columnBits = ceil(log2f($Display::WIDTH));

        columnCorr = calloc($Camera::WIDTH * $Camera::HEIGHT, sizeof(uint16_t));

        for (int k = columnBits - 1; k >= 0; k--) {
            DRAW("Gpu::draw {$columnGrayCode} %d 0", k);
            uint8_t* codeImage = delayThenCameraCapture(interp, "columnCodeImage");

            DRAW("Gpu::draw {$columnGrayCode} %d 1", k);
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "columnInvertedCodeImage");

            // scan camera image, add to the correspondence for each pixel
            $[eachCameraPixel {
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

            // TODO: these are allocated from the Folk heap now
            // ckfree(codeImage);
            // ckfree(invertedCodeImage);
        }

        // convert column correspondences out of Gray code
        $[eachCameraPixel {
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
            DRAW("Gpu::draw {$rowGrayCode} %d 0", k);
            uint8_t* codeImage = delayThenCameraCapture(interp, "rowCodeImage");

            DRAW("Gpu::draw {$rowGrayCode} %d 1", k);
            uint8_t* invertedCodeImage = delayThenCameraCapture(interp, "rowInvertedCodeImage");

            // scan camera image, add to the correspondence for each pixel
            $[eachCameraPixel {
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

            // TODO: these are allocated from the Folk heap now
            // ckfree(codeImage);
            // ckfree(invertedCodeImage);
        }

        // convert row correspondences out of Gray code
        $[eachCameraPixel {
            if (rowCorr[i] != 0xFFFF) {
                rowCorr[i] = fromGrayCode(rowCorr[i]);
            }
        }]
    }

    dense_t* dense = malloc(sizeof(dense_t));
    dense->columnCorr = columnCorr;
    dense->rowCorr = rowCorr;
    return dense;
}

$cc proc displayDenseCorrespondence {Tcl_Interp* interp dense_t* dense} void {
    // TODO: Bring this back. Temporarily disabling so I don't have to
    // port it to GPU. (and we weren't really using it, anyway, afaict.)

    /* // image the base scene in black for reference */
    /* [eachDisplayPixel { *it = BLACK; }] */
    /* uint8_t* blackImage = delayThenCameraCapture(interp, "displayBlackImage"); */

    /* // display dense correspondence directly. just for fun */
    /* [eachCameraPixel [subst -nocommands -nobackslashes { */
    /*     if (dense->columnCorr[i] == 0 && dense->rowCorr[i] == 0) { // ??? */
    /*         fb[(y * $Display::WIDTH) + x] = PIXEL(255, 255, 0); */
    /*     } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] == 0xFFFF) { */
    /*         uint8_t pix = blackImage[i]; */
    /*         fb[(y * $Display::WIDTH) + x] = PIXEL(pix, pix, pix); */
    /*     } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] != 0xFFFF) { */
    /*         fb[(y * $Display::WIDTH) + x] = PIXEL(255, 0, 0); // red: row-only match */
    /*     } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] == 0xFFFF) { */
    /*         fb[(y * $Display::WIDTH) + x] = PIXEL(0, 0, 255); // blue: column-only match */
    /*     } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) { */
    /*         fb[(y * $Display::WIDTH) + x] = PIXEL(0, 255, 0); // green: double match */
    /*     } */
    /* }]] */
}

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

set dense [findDenseCorrespondence]
puts "dense: $dense"
displayDenseCorrespondence $dense

set detector [AprilTags new $tagfamily]
set grayFrame [Camera::grayFrame]
set tags [$detector detect $grayFrame]
Camera::freeImage $grayFrame

Display::start

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
    Display::text $px $py 2 "$id" 0
    Display::text $px1 $py1 2 "$id'" 0
    
    lappend keyCorrespondences [lindex $correspondences 0]
}
Display::end
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

exec sleep 10
# exec sudo systemctl start folk &
