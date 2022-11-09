package require critcl
source "pi/critclUtils.tcl"

namespace eval Display {}
set fbset [exec fbset]
regexp {mode "(\d+)x(\d+)"} $fbset -> Display::WIDTH Display::HEIGHT
regexp {geometry \d+ \d+ \d+ \d+ (\d+)} $fbset -> Display::DEPTH

critcl::tcl 8.6
critcl::cflags -Wall -Werror

critcl::ccode {
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <sys/mman.h>
    #include <stdint.h>
    #include <string.h>
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
        #define PIXEL_R(pixel) (((pixel) >> 16) | 0xFF)
        #define PIXEL_G(pixel) (((pixel) >> 8) | 0xFF)
        #define PIXEL_B(pixel) (((pixel) >> 0) | 0xFF)
        #define PIXEL(r, g, b) (((r) << 16) | ((g) << 8) | ((b) << 0))
    }
} else {
    error "Display: Unusable depth $Display::DEPTH"
}

critcl::ccode {
    typedef struct {
        unsigned width;
        unsigned height;
        pixel_t* pixels;
    } drawable_surface_t;
    
    drawable_surface_t staging;
    drawable_surface_t fb;
}
critcl::clean_cache
critcl::argtype drawable_surface_t {
    sscanf(Tcl_GetString(@@), "%d %d 0x%p", &@A.width, &@A.height, &@A.pixels);
} drawable_surface_t
critcl::resulttype drawable_surface_t {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d 0x%" PRIxPTR, rv.width, rv.height, (uintptr_t) rv.pixels));
    return TCL_OK;
} drawable_surface_t

critcl::ccode [source "vendor/font.tcl"]
opaquePointerType pixel_t*
opaquePointerType uint8_t*

critcl::cproc mmapFb {int fbw int fbh} drawable_surface_t {
    int fbfd = open("/dev/fb0", O_RDWR);
    fb.width = fbw; fb.height = fbh;
    fb.pixels = mmap(NULL, fbw * fbh * sizeof(pixel_t), PROT_WRITE, MAP_SHARED, fbfd, 0);
    staging.width = fbw; staging.height = fbh;
    staging.pixels = calloc(fbw * fbh, sizeof(pixel_t));
    return staging;
}

critcl::ccode {
    typedef struct Vec2i { int x; int y; } Vec2i;
    Vec2i Vec2i_add(Vec2i a, Vec2i b) { return (Vec2i) { a.x + b.x, a.y + b.y }; }
    Vec2i Vec2i_sub(Vec2i a, Vec2i b) { return (Vec2i) { a.x - b.x, a.y - b.y }; }
    Vec2i Vec2i_scale(Vec2i a, float s) { return (Vec2i) { a.x*s, a.y*s }; }
}
critcl::argtype Vec2i {
    sscanf(Tcl_GetString(@@), "%d %d", &@A.x, &@A.y);
} Vec2i
critcl::resulttype Vec2i {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d", rv.x, rv.y));
    return TCL_OK;
} Vec2i
critcl::cproc fillTriangleImpl {drawable_surface_t surface Vec2i t0 Vec2i t1 Vec2i t2 bytes colorBytes} void {
    unsigned short color = (colorBytes.s[1] << 8) | colorBytes.s[0];

    // from https://github.com/ssloy/tinyrenderer/wiki/Lesson-2:-Triangle-rasterization-and-back-face-culling

    if (t0.y==t1.y && t0.y==t2.y) return; // I dont care about degenerate triangles 
    // sort the vertices, t0, t1, t2 lower−to−upper (bubblesort yay!)
    Vec2i tmp;
    if (t0.y>t1.y) { tmp = t0; t0 = t1; t1 = tmp; }
    if (t0.y>t2.y) { tmp = t0; t0 = t2; t2 = tmp; }
    if (t1.y>t2.y) { tmp = t1; t1 = t2; t2 = tmp; }
    int total_height = t2.y-t0.y;
    for (int i=0; i<total_height; i++) {
        int second_half = i>(t1.y-t0.y) || t1.y==t0.y;
        int segment_height = second_half ? t2.y-t1.y : t1.y-t0.y; 
        float alpha = (float)i/total_height; 
        float beta  = (float)(i-(second_half ? t1.y-t0.y : 0))/segment_height; // be careful: with above conditions no division by zero here 
        Vec2i A =               Vec2i_add(t0, Vec2i_scale(Vec2i_sub(t2, t0), alpha)); 
        Vec2i B = second_half ? Vec2i_add(t1, Vec2i_scale(Vec2i_sub(t2, t1), beta)) : Vec2i_add(t0, Vec2i_scale(Vec2i_sub(t1, t0), beta)); 
        if (A.x>B.x) { tmp = A; A = B; B = tmp; }
        for (int j=A.x; j<=B.x; j++) {
            surface.pixels[(t0.y+i)*surface.width + j] = color; // attention, due to int casts t0.y+i != A.y 
        } 
    } 
}

critcl::cproc drawText {drawable_surface_t surface int x0 int y0 pstring text} void {
    // Draws 1 line of text (no linebreak handling).
    size_t width = text.len * font.char_width;
    size_t height = font.char_height;
    if (x0 < 0 || y0 < 0 ||
        x0 + width >= surface.width || y0 + height >= surface.height) return;

    /* printf("%d x %d\n", font.char_width, font.char_height); */
    /* printf("[%c] (%d)\n", c, c); */

    for (unsigned i = 0; i < text.len; i++) {
        for (unsigned y = 0; y < font.char_height; y++) {
            for (unsigned x = 0; x < font.char_width; x++) {
                int idx = (text.s[i] * font.char_height * 2) + (y * 2) + (x >= 8 ? 1 : 0);
                int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
                surface.pixels[(y0+y)*surface.width + (x0+x + i*font.char_width)] = bit ? 0xFFFF : 0x0000;
            }
        }
    }
}
# for debugging
critcl::cproc drawGrayImage {pixel_t* fbmem int fbwidth int fbheight uint8_t* im int width int height} void {
 for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
              int i = (y * width + x);
              uint8_t r = im[i];
              uint8_t g = im[i];
              uint8_t b = im[i];
              int fbx = x + 300;
              int fby = y + 300;
              if (fbx >= fbwidth || fby >= fbheight) continue;
              fbmem[(fby * fbwidth) + fbx] = PIXEL(r, g, b);                  
          }
      }
}
critcl::cproc commitThenClearStaging {} void {
    memcpy(fb.pixels, staging.pixels, fb.width * fb.height * sizeof(pixel_t));
    memset(staging.pixels, 0, staging.width * staging.height * sizeof(pixel_t));
    // memset(fb.pixels, 0xFF, fb.width * fb.height * sizeof(pixel_t));
}

namespace eval Display {
    variable WIDTH
    variable HEIGHT
    variable DEPTH

    if {$Display::DEPTH == 16} {
        variable black [binary format b16 [join {00000 000000 00000} ""]]
        variable blue  [binary format b16 [join {11111 000000 00000} ""]]
        variable green [binary format b16 [join {00000 111111 00000} ""]]
        variable red   [binary format b16 [join {00000 000000 11111} ""]]
        variable white [binary format b16 [join {11111 111111 11111} ""]]
    } elseif {$Display::DEPTH == 32} {
        variable black [binary format b16 [join {00000000 00000000 00000000} ""]]
        variable blue  [binary format b16 [join {11111111 00000000 00000000} ""]]
        variable green [binary format b16 [join {00000000 11111111 00000000} ""]]
        variable red   [binary format b16 [join {00000000 00000000 11111111} ""]]
        variable white [binary format b16 [join {11111111 11111111 11111111} ""]]
    }

    variable surface

    package require math::linearalgebra
    
    # functions
    # ---------
    proc init {} {
        set Display::surface [mmapFb $Display::WIDTH $Display::HEIGHT]
    }

    proc vec2i {p} {
        return [list [expr {int([lindex $p 0])}] [expr {int([lindex $p 1])}]]
    }
    proc fillTriangle {surface p0 p1 p2 color} {
        fillTriangleImpl $surface [vec2i $p0] [vec2i $p1] [vec2i $p2] [set Display::$color]
    }
    proc stroke {surface points width color} {
        for {set i 0} {$i < [llength $points]} {incr i} {
            set a [lindex $points $i]
            set b [lindex $points [expr $i+1]]
            if {$b == ""} break

            set bMinusA [math::linearalgebra::sub $b $a]
            set nudge [list [lindex $bMinusA 1] [expr {[lindex $bMinusA 0]*-1}]]
            set nudge [math::linearalgebra::scale $width [math::linearalgebra::unitLengthVector $nudge]]

            set a0 [math::linearalgebra::add $a $nudge]
            set a1 [math::linearalgebra::sub $a $nudge]
            set b0 [math::linearalgebra::add $b $nudge]
            set b1 [math::linearalgebra::sub $b $nudge]
            fillTriangle $surface $a0 $a1 $b1 $color
            fillTriangle $surface $a0 $b0 $b1 $color
        }
    }

    proc text {surface x y fontSize text} {
        drawText $surface [expr {int($x)}] [expr {int($y)}] $text
    }

    # for debugging
    proc grayImage {args} { drawGrayImage {*}$args }

    proc commit {} { commitThenClearStaging }
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    Display::init

    for {set i 0} {$i < 5} {incr i} {
        Display::fillTriangle $Display::surface {400 400} {500 500} {400 600} blue
        # fillRectangle 400 400 410 410 $Display::red ;# t0
        # fillRectangle 500 500 510 510 $Display::red ;# t1
        # fillRectangle 400 600 410 610 $Display::red ;# t2
        
        drawText $Display::surface 300 400 "A"
        drawText $Display::surface 309 400 "B" 
        drawText $Display::surface 318 400 "O"

        Display::text $Display::surface 300 420 PLACEHOLDER "Hello!"

        puts [time Display::commit]
    }
}
