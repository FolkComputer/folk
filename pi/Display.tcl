source "lib/c.tcl"
source "pi/cUtils.tcl"

namespace eval Display {}
set fbset [exec fbset]
regexp {mode "(\d+)x(\d+)"} $fbset -> Display::WIDTH Display::HEIGHT
regexp {geometry \d+ \d+ \d+ \d+ (\d+)} $fbset -> Display::DEPTH

rename [c create] dc

dc code {
    #include <sys/stat.h>
    #include <fcntl.h>
    #include <sys/mman.h>
    #include <stdint.h>
    #include <string.h>
    #include <stdlib.h>
    #include <math.h>
}

if {$Display::DEPTH == 16} {
    dc code {
        typedef uint16_t pixel_t;
        #define PIXEL(r, g, b) \
            (((((r) >> 3) & 0x1F) << 11) | \
             ((((g) >> 2) & 0x3F) << 5) | \
             (((b) >> 3) & 0x1F));
    }
} elseif {$Display::DEPTH == 32} {
    dc code {
        typedef uint32_t pixel_t;
        #define PIXEL_R(pixel) (((pixel) >> 16) | 0xFF)
        #define PIXEL_G(pixel) (((pixel) >> 8) | 0xFF)
        #define PIXEL_B(pixel) (((pixel) >> 0) | 0xFF)
        #define PIXEL(r, g, b) (((r) << 16) | ((g) << 8) | ((b) << 0))
    }
} else {
    error "Display: Unusable depth $Display::DEPTH"
}

dc code {
    pixel_t* staging;
    pixel_t* fbmem;

    int fbwidth;
    int fbheight;
}
dc code [source "vendor/font.tcl"]

dc proc mmapFb {int fbw int fbh} pixel_t* {
    int fb = open("/dev/fb0", O_RDWR);
    fbwidth = fbw;
    fbheight = fbh;
    fbmem = mmap(NULL, fbwidth * fbheight * sizeof(pixel_t), PROT_WRITE, MAP_SHARED, fb, 0);
    // Multiply by 3 to create buffer area
    staging = calloc(fbwidth * fbheight * 3, sizeof(pixel_t)) + (fbwidth * fbheight * sizeof(pixel_t));
    return fbmem;
}

dc code {
    typedef struct Vec2i { int x; int y; } Vec2i;
    Vec2i Vec2i_add(Vec2i a, Vec2i b) { return (Vec2i) { a.x + b.x, a.y + b.y }; }
    Vec2i Vec2i_sub(Vec2i a, Vec2i b) { return (Vec2i) { a.x - b.x, a.y - b.y }; }
    Vec2i Vec2i_scale(Vec2i a, float s) { return (Vec2i) { a.x*s, a.y*s }; }
}
dc argtype Vec2i {
    Vec2i $argname; sscanf(Tcl_GetString($obj), "%d %d", &$argname.x, &$argname.y);
}
dc rtype Vec2i {
    $robj = Tcl_ObjPrintf("%d %d", rv.x, rv.y);
}

source "pi/lineclip.tcl"

dc proc fillTriangleImpl {Vec2i t0 Vec2i t1 Vec2i t2 int color} void {
    if (t0.x < 0 || t0.y < 0 || t1.x < 0 || t1.y < 0 || t2.x < 0 || t2.y < 0 ||
        t0.x >= fbwidth || t0.y >= fbheight || t1.x >= fbwidth || t1.y >= fbheight || t2.x >= fbwidth || t2.y >= fbheight) {
         return;
    }

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
            staging[(t0.y+i)*fbwidth + j] = color; // attention, due to int casts t0.y+i != A.y 
        } 
    } 
}
dc code {
#define plot(x, y) if ((x) >= 0 && (x) < fbwidth && (y) >= 0 && (y) < fbheight) staging[(y)*fbwidth + (x)] = color
}
dc proc drawCircle {int x0 int y0 int radius int color} void {
    int f = 1 - radius;
    int ddF_x = 0;
    int ddF_y = -2 * radius;
    int x = 0;
    int y = radius;

    plot(x0, y0 + radius);
    plot(x0, y0 - radius);
    plot(x0 + radius, y0);
    plot(x0 - radius, y0);

    while(x < y) 
    {
        if(f >= 0) 
        {
            y--;
            ddF_y += 2;
            f += ddF_y;
        }
        x++;
        ddF_x += 2;
        f += ddF_x + 1;    
        plot(x0 + x, y0 + y);
        plot(x0 - x, y0 + y);
        plot(x0 + x, y0 - y);
        plot(x0 - x, y0 - y);
        plot(x0 + y, y0 + x);
        plot(x0 - y, y0 + x);
        plot(x0 + y, y0 - x);
        plot(x0 - y, y0 - x);
    }
}

dc proc drawText {int x0 int y0 int upsidedown int scale char* text} void {
    // Draws 1 line of text (no linebreak handling).
    // TODO: upsidedown/radians is still funky
    int len = strlen(text);
    int S = upsidedown ? -1 : 1;

    for (unsigned i = 0; i < len; i++) {
	int N = upsidedown ? len-i-1 : i;
	int letterOffset = text[N] * font.char_height * 2;

	// Loop over the font bitmap
	for (unsigned y = 0; y < font.char_height; y++) {
	    for (unsigned x = 0; x < font.char_width; x++) {

		// Index into bitmap for pixel
		int idx = letterOffset + (y * 2) + (x >= 8 ? 1 : 0);
		int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
		if (!bit) continue;

		// When bit is on, repeat to scale to font-size
		for (int dy = 0; dy < scale; dy++) {
		    for (int dx = 0; dx < scale; dx++) {

            int sx = x0 + S * (scale * x + dx + N * scale * font.char_width);
			int sy = y0 + S * (scale * y + dy);
			if (sx < 0 || fbwidth <= sx || sy < 0 || fbheight <= sy) continue;

			staging[sy*fbwidth + sx] = 0xFFFF;
		    }
		}
	    }
	}
    }
}

defineImageType dc
dc proc drawImage {int x0 int y0 image_t image int scale} void {
    for (int y = 0; y < image.height; y++) {
        for (int x = 0; x < image.width; x++) {

	    // Index into image to get color
            int i = y*image.bytesPerRow + x*image.components;
            uint8_t r; uint8_t g; uint8_t b;
            if (image.components == 3) {
                r = image.data[i]; g = image.data[i+1]; b = image.data[i+2];
            } else if (image.components == 1) {
                r = image.data[i]; g = image.data[i]; b = image.data[i];
            } else {
                exit(1);
            }

	    // Write repeatedly to framebuffer to scale up image
	    for (int dy = 0; dy < scale; dy++) {
		for (int dx = 0; dx < scale; dx++) {

		    int sx = x0 + scale * x + dx;
		    int sy = y0 + scale * y + dy;
		    if (sx < 0 || fbwidth <= sx || sy < 0 || fbheight <= sy) continue;

		    staging[sy*fbwidth + sx] = PIXEL(r, g, b);

		}
	    }
        }
    }
}

# for debugging
dc proc drawGrayImage {pixel_t* fbmem int fbwidth int fbheight uint8_t* im int width int height} void {
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
dc proc commitThenClearStaging {} void {
    memcpy(fbmem, staging, fbwidth * fbheight * sizeof(pixel_t));
    memset(staging, 0, fbwidth * fbheight * sizeof(pixel_t));
}

dc compile

namespace eval Display {
    variable WIDTH
    variable HEIGHT
    variable DEPTH

    proc color {b g r} { expr 0b[join [list $r $g $b] ""] }
    source "pi/Colors.tcl"

    variable fb

    lappend auto_path "./vendor"
    package require math::linearalgebra
    
    # functions
    # ---------
    proc init {} {
        set Display::fb [mmapFb $Display::WIDTH $Display::HEIGHT]
    }

    proc vec2i {p} {
        return [list [expr {int([lindex $p 0])}] [expr {int([lindex $p 1])}]]
    }

    proc getColor {color} {
        if {[info exists Display::$color]} {
            set Display::$color
        } elseif {[string is integer $color]} {
            set color
        } else {
            set Display::white
        }
    }

    proc fillTriangle {p0 p1 p2 color} {
        fillTriangleImpl [vec2i $p0] [vec2i $p1] [vec2i $p2] [getColor $color]
    }

    proc fillQuad {p0 p1 p2 p3 color} {
      fillTriangle $p1 $p2 $p3 color
      fillTriangle $p0 $p1 $p3 color
    }

    proc fillPolygon {points color} {
        set num_points [llength $points]
        if {$num_points < 3} {
            error "At least 3 points are required to form a polygon."
        } elseif {$num_points == 3} {
            eval fillTriangle $points $color
        } elseif {$num_points == 4} {
            eval fillQuad $points $color
        } else {
            # Get the first point in the list as the "base" point of the triangles
            set p0 [lindex $points 0]

            for {set i 1} {$i < $num_points - 1} {incr i} {
                set p1 [lindex $points $i]
                set p2 [lindex $points [expr {$i+1}]]
                fillTriangle $p0 $p1 $p2 $color
            }
        }
    }

    proc stroke {points width color} {
        for {set i 0} {$i < [expr {[llength $points] - 1}]} {incr i} {
            try {
                set a [lindex $points $i]
                set b [lindex $points [expr $i+1]]

                # if line is past edge of screen, clip it to the nearest
                # point along edge of screen
                clipLine a b $width

                set bMinusA [math::linearalgebra::sub $b $a]
                set nudge [list [lindex $bMinusA 1] [expr {[lindex $bMinusA 0]*-1}]]
                set nudge [math::linearalgebra::scale $width [math::linearalgebra::unitLengthVector $nudge]]

                set a0 [math::linearalgebra::add $a $nudge]
                set a1 [math::linearalgebra::sub $a $nudge]
                set b0 [math::linearalgebra::add $b $nudge]
                set b1 [math::linearalgebra::sub $b $nudge]
                fillTriangle $a0 $a1 $b1 [getColor $color]
                fillTriangle $a0 $b0 $b1 [getColor $color]
            } on error e {}
        }
    }

    proc text {fb x y scale text radians} {
	set upsidedown [expr {abs($radians) > 1.57}]
        drawText [expr {int($x)}] [expr {int($y)}] $upsidedown $scale $text
    }

    proc circle {x y radius thickness color} {
        for {set i 0} {$i < $thickness} {incr i} {
            drawCircle [expr {int($x)}] [expr {int($y)}] [expr {int($radius+$i)}] [getColor $color]
        }
    }

    proc image {x y im {scale 1.0}} {
        drawImage [expr {int($x)}] [expr {int($y)}] $im [expr {int($scale)}]
    }

    # for debugging
    proc grayImage {args} { drawGrayImage {*}$args }

    proc commit {} {
        commitThenClearStaging
    }
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    Display::init

    for {set i 0} {$i < 5} {incr i} {
        fillTriangleImpl {400 400} {500 500} {400 600} $Display::blue
        
        drawText 309 400 "B" 0
        drawText 318 400 "O" 0

        drawCircle 100 100 500 $Display::red

        Display::circle 300 420 400 5 blue
        Display::text fb 300 420 PLACEHOLDER "Hello!" 0

        puts [time Display::commit]
    }
}
