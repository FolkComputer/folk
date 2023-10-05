source "lib/language.tcl"
source "lib/c.tcl"

exec sudo systemctl stop folk
# TODO: Fix this hack.
set thisPid [pid]
foreach pid [try { exec pgrep tclsh8.6 } on error e { list }] {
    if {$pid ne $thisPid} {
        try { exec kill -9 $pid } on error e { puts stderr $e }
    }
}
exec sleep 1

catch { exec v4l2-ctl --set-ctrl=focus_auto=0 }
catch { exec v4l2-ctl --set-ctrl=focus_absolute=0 }
catch { exec v4l2-ctl -c white_balance_automatic=0 }
catch { exec v4l2-ctl -c auto_exposure=1 }

# FIXME: These are hacks/stubs so we can just load images.folk
# without needing any other Folk stuff.
proc When {args} {}
set ::isLaptop false

source "pi/Camera.tcl"
source "pi/AprilTags.tcl"
source "pi/Gpu.tcl"

source "virtual-programs/images.folk"
source "pi/cUtils.tcl"

# FIXME: adapt to camera spec
# Camera::init 3840 2160
Camera::init 1920 1080
set tagfamily "tagStandard52h13"

Gpu::init
Gpu::ImageManager::imageManagerInit

set cc [c create]
::defineImageType $cc

$cc code {
    #include <stdint.h>
    #include <unistd.h>
    #include <stdlib.h>
    #include <math.h>
}

$cc import ::image::cc saveAsJpeg as saveAsJpeg

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

$cc code [csubst {
    #include <jpeglib.h>

    #define CAMERA_WIDTH $Camera::WIDTH
    #define CAMERA_HEIGHT $Camera::HEIGHT

    int captureNum = 0;

    int captureAndGetBrightness(Tcl_Interp* interp, uint8_t** outImage) {
        Tcl_Eval(interp, "set rgb [Camera::frame]; set gray [Camera::rgbToGray \$rgb]; Camera::freeImage \$rgb; dict get \$gray data");
        if (outImage == NULL) outImage = alloca(sizeof(uint8_t*));
        sscanf(Tcl_GetStringResult(interp), "(uint8_t*) 0x%p", outImage);
        Tcl_ResetResult(interp);

        double brightness = 0;
        $[eachCameraPixel { brightness += (*outImage)[i]; }]
        brightness /= $Camera::WIDTH * $Camera::HEIGHT;
        return (int)brightness;
    }
    int numberOfFramesToStabilize;
    void determineNumberOfFramesToStabilize(Tcl_Interp* interp, int startBrightness, int endBrightness) {
        /* fprintf(stderr, "start: %d -> end: %d\n", startBrightness, endBrightness); */
        bool closer(int this, int that, int x) { return abs(this - x) < abs(that - x); }
        int lastSeenBrightnesses[5] = {startBrightness, startBrightness, startBrightness, startBrightness, startBrightness};
        int numberOfFrames = 0;
        int brightness;
        do {
            numberOfFrames++;
            brightness = captureAndGetBrightness(interp, NULL);
            /* fprintf(stderr, "brightness: %d\n", brightness); */

            for (int i = 0; i < 4; i++) {
                lastSeenBrightnesses[i] = lastSeenBrightnesses[i + 1];
            }
            lastSeenBrightnesses[4] = brightness;

        } while (closer(startBrightness, endBrightness, lastSeenBrightnesses[4]) ||
                 closer(startBrightness, endBrightness, lastSeenBrightnesses[3]));

        numberOfFramesToStabilize = numberOfFrames;
    }

    uint8_t* delayThenCameraCapture(Tcl_Interp* interp, const char* description) {
        for (int i = 0; i < numberOfFramesToStabilize; i++) {
            Tcl_Eval(interp, "Camera::freeImage [Camera::frame]");
        }
        Tcl_Eval(interp, "set rgb [Camera::frame]; set gray [Camera::rgbToGray \$rgb]; Camera::freeImage \$rgb; dict get \$gray data");
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
        image_t im = (image_t) { .data = image, .width = width, .height = height, .components = 1, .bytesPerRow = width };
        saveAsJpeg(im, filename);

        return image;
    }
}]

$cc code {
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

$cc code {
    #define DRAW(...) do { Tcl_Eval(interp, "Gpu::drawStart"); __ENSURE_OK(Tcl_EvalObjEx(interp, Tcl_ObjPrintf(__VA_ARGS__), 0)); Tcl_Eval(interp, "Gpu::drawEnd"); } while (0)
}
# returns dense correspondence from camera space -> projector space
$cc proc findDenseCorrespondence {Tcl_Interp* interp} dense_t* {
    // image the base scene in black
    DRAW("Gpu::draw {$clearScreen} {0 0 0 1}");
    uint8_t* blackImage;
    for (int i = 0; i < 8; i++) captureAndGetBrightness(interp, &blackImage);
    int blackBrightness = captureAndGetBrightness(interp, &blackImage);
    fprintf(stderr, "black: %d\n", blackBrightness);

    // image the base scene in white
    DRAW("Gpu::draw {$clearScreen} {1 1 1 1}");
    uint8_t* whiteImage;
    for (int i = 0; i < 8; i++) captureAndGetBrightness(interp, &whiteImage);
    int whiteBrightness = captureAndGetBrightness(interp, &whiteImage);
    fprintf(stderr, "white: %d\n", whiteBrightness);

    // go back to black, then figure out how long the black takes to appear on cam.
    DRAW("Gpu::draw {$clearScreen} {0 0 0 1}");
    DRAW("Gpu::draw {$clearScreen} {0 0 0 1}"); // TODO: why do I have to draw twice??
    determineNumberOfFramesToStabilize(interp, whiteBrightness, blackBrightness);
    fprintf(stderr, "number of frames to stabilize: %d\n", numberOfFramesToStabilize);

    // find column correspondences:
    uint16_t* columnCorr;
    {
        // how many bits do we need in the Gray code?
        int columnBits = ceil(log2f($Gpu::WIDTH));

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
        int rowBits = ceil(log2f($Gpu::WIDTH));

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
    DRAW("Gpu::draw {$clearScreen} {0 0 0 1}");
    uint8_t* blackImage = delayThenCameraCapture(interp, "blackImage");
    image_t im = (image_t) { .width = $Camera::WIDTH, .height = $Camera::HEIGHT,
        .bytesPerRow = $Camera::WIDTH * 3, .components = 3,
        .data = ckalloc($Camera::WIDTH * $Camera::HEIGHT * 3) };

    // render dense correspondence for debugging
#define PIXEL(r, g, b) im.data[i*3] = r; im.data[i*3 + 1] = g; im.data[i*3 + 2] = b
    $[eachCameraPixel [subst -nocommands -nobackslashes {
        if (dense->columnCorr[i] == 0 && dense->rowCorr[i] == 0) { // ???
            PIXEL(255, 255, 0);
        } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            uint8_t pix = blackImage[i];
            PIXEL(pix, pix, pix);
        } else if (dense->columnCorr[i] == 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            PIXEL(255, 0, 0); // red: row-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] == 0xFFFF) {
            PIXEL(0, 0, 255); // blue: column-only match
        } else if (dense->columnCorr[i] != 0xFFFF && dense->rowCorr[i] != 0xFFFF) {
            PIXEL(0, 255, 0); // green: double match
        }
    }]]
    
    // write capture to jpeg
    saveAsJpeg(im, "dense-correspondence.jpeg");
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
    // printf("correspondenceCount: %d\n", correspondenceCount);

    return Tcl_NewListObj(correspondenceCount, correspondences);
}]

$cc compile

puts "camera: $Camera::camera"

set dense [findDenseCorrespondence]
displayDenseCorrespondence $dense

set detector [AprilTags new $tagfamily]
set grayFrame [Camera::grayFrame]
set tags [$detector detect $grayFrame]
Camera::freeImage $grayFrame

flush stdout


set fillTriangle [Gpu::pipeline {vec2 p0 vec2 p1 vec2 p2 vec4 color} {
    vec2 vertices[4] = vec2[4](p0, p1, p2, p0);
    return vertices[gl_VertexIndex];
} {
    return color;
}]

Gpu::drawStart

puts ""
set keyCorrespondences [list]
foreach tag $tags {
    puts ""
    puts "Checking tag $tag."
    
    # these are in camera space
    set cx [lindex [dict get $tag center] 0]
    set cy [lindex [dict get $tag center] 1]

    set keypoints [list [list $cx $cy] {*}[dict get $tag corners]]
    # puts "keypoints: $keypoints"
    set correspondences [list]
    foreach keypoint $keypoints {
        lassign $keypoint x y
        set nearby [findNearbyCorrespondences $dense [expr {int($x)}] [expr {int($y)}] 3]
        if {[llength $nearby] > 0} {
            lappend correspondences [lindex $nearby 0]
        }
    }

    if {[llength $correspondences] == 0} { continue }
    # puts "nearby: [llength $correspondences] correspondences: $correspondences"
    # puts ""

    lassign [lindex $correspondences 0] _ _ px py
    lassign [lindex $correspondences end] _ _ px1 py1
    # puts "$px $py $px1 $py1"
    Gpu::draw $fillTriangle \
        [list $px $py] \
        [list $px1 $py1] \
        [list $px $py1] \
        {1 0 0 1}
    # set id [dict get $tag id]
    # Gpu::text $px $py 2 "$id" 0
    # Gpu::text $px1 $py1 2 "$id'" 0
    
    lappend keyCorrespondences [lindex $correspondences 0]
}
Gpu::drawEnd

puts ""
puts "Found [llength $keyCorrespondences] key correspondences: $keyCorrespondences"
if {[llength $keyCorrespondences] >= 4} {
    puts "Calibration succeeded!"

    set keyCorrespondences [lrange $keyCorrespondences 0 3] ;# can only use 4 points

    set fd [open "/home/folk/generated-calibration.tcl" w]
    puts $fd [subst {
        namespace eval generatedCalibration {
            variable cameraWidth $Camera::WIDTH
            variable cameraHeight $Camera::HEIGHT
            variable displayWidth $Gpu::WIDTH
            variable displayHeight $Gpu::HEIGHT
            variable points {$keyCorrespondences}
        }
    }]
    close $fd

} else {
    puts "Calibration did not succeed. Not enough points found."
}

exec sleep 10
# exec sudo systemctl start folk &
