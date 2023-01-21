source "lib/c.tcl"
source "pi/cUtils.tcl"
source "./Colors.tcl"

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
    sscanf(Tcl_GetString($obj), "%d %d", &$argname.x, &$argname.y);
}
dc rtype Vec2i {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d", rv.x, rv.y));
    return TCL_OK;
}

source "pi/Display/lineclip.tcl"

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

dc proc drawText {int x0 int y0 int upsidedown char* text} void {
    // Draws 1 line of text (no linebreak handling).

    /* size_t width = text.len * font.char_width; */
    /* size_t height = font.char_height; */
    /* if (x0 < 0 || y0 < 0 || */
    /*     x0 + width >= fbwidth || y0 + height >= fbheight) return; */

    /* printf("%d x %d\n", font.char_width, font.char_height); */
    /* printf("[%c] (%d)\n", c, c); */

    int len = strlen(text);
    if (upsidedown) {
        for (unsigned i = 0; i < len; i++) {
            for (unsigned y = 0; y < font.char_height; y++) {
                for (unsigned x = 0; x < font.char_width; x++) {
                    int idx = (text[i] * font.char_height * 2) + (y * 2) + (x >= 8 ? 1 : 0);
                    int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;

                    int sx = ((len-i)*font.char_width + x0-x);
                    int sy = y0 - y;
                    if (sx >= 0 && sx < fbwidth && sy >= 0 && sy < fbheight) {
                        staging[(sy*fbwidth) + sx] = bit ? 0xFFFF : 0x0000;
                    }
                }
            }
        }   
    } else {
        for (unsigned i = 0; i < len; i++) {
            for (unsigned y = 0; y < font.char_height; y++) {
                for (unsigned x = 0; x < font.char_width; x++) {
                    int idx = (text[i] * font.char_height * 2) + (y * 2) + (x >= 8 ? 1 : 0);
                    int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;

                    int sx = (i*font.char_width + x0+x);
                    int sy = y0 + y;
                    if (sx >= 0 && sx < fbwidth && sy >= 0 && sy < fbheight) {
                        staging[(sy*fbwidth) + sx] = bit ? 0xFFFF : 0x0000;
                    }
                }
            }
        }
    }
}

defineImageType dc
dc proc drawImage {int x0 int y0 image_t image} void {
    for (int y = 0; y < image.height; y++) {
        for (int x = 0; x < image.width; x++) {
            int i = y*image.bytesPerRow + x*image.components;
            uint8_t r = image.data[i];
            uint8_t g = image.data[i+1];
            uint8_t b = image.data[i+2];
            staging[(y0+y)*fbwidth + x0+x] = PIXEL(r, g, b);
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
    proc dec2bin5 int {
        set binRep [binary format c $int]
        binary scan $binRep B5 binStr
        return $binStr
    }
    proc dec2bin6 int {
        set binRep [binary format c $int]
        binary scan $binRep B6 binStr
        return $binStr
    }
    proc dec2bin8 int {
        set binRep [binary format c $int]
        binary scan $binRep B8 binStr
        return $binStr
    }
    proc hex2fbColor color {
        set r [expr {$color & 0xFF}]
        set g [expr {($color >> 8) & 0xFF}]
        set b [expr {($color >> 16) & 0xFF}]

        set fbColor "\[[dec2bin8 $b]\] \[[dec2bin8 $g]\] \[[dec2bin8 $r]\]"
        if {$Display::DEPTH == 16} {
            return [color [dec2bin5 $b] [dec2bin6 $g] [dec2bin5 $r]]
        } elseif {$Display::DEPTH == 32} {
            return [color [dec2bin8 $b] [dec2bin8 $g] [dec2bin8 $r]]
        }
    }

    variable aliceblue [hex2dec F0F8FF]
    variable antiquewhite [hex2dec FAEBD7]
    variable aqua [hex2dec 00FFFF]
    variable aquamarine [hex2dec 7FFFD4]
    variable azure [hex2dec F0FFFF]
    variable beige [hex2dec F5F5DC]
    variable bisque [hex2dec FFE4C4]
    variable black [hex2dec 000000]
    variable blanchedalmond [hex2dec FFEBCD]
    variable blue [hex2dec 0000FF]
    variable blueviolet [hex2dec 8A2BE2]
    variable brown [hex2dec A52A2A]
    variable burlywood [hex2dec DEB887]
    variable cadetblue [hex2dec 5F9EA0]
    variable chartreuse [hex2dec 7FFF00]
    variable chocolate [hex2dec D2691E]
    variable coral [hex2dec FF7F50]
    variable cornflowerblue [hex2dec 6495ED]
    variable cornsilk [hex2dec FFF8DC]
    variable crimson [hex2dec DC143C]
    variable cyan [hex2dec 00FFFF]
    variable darkblue [hex2dec 00008B]
    variable darkcyan [hex2dec 008B8B]
    variable darkgoldenrod [hex2dec B8860B]
    variable darkgray [hex2dec A9A9A9]
    variable darkgreen [hex2dec 006400]
    variable darkgrey [hex2dec A9A9A9]
    variable darkkhaki [hex2dec BDB76B]
    variable darkmagenta [hex2dec 8B008B]
    variable darkolivegreen [hex2dec 556B2F]
    variable darkorange [hex2dec FF8C00]
    variable darkorchid [hex2dec 9932CC]
    variable darkred [hex2dec 8B0000]
    variable darksalmon [hex2dec E9967A]
    variable darkseagreen [hex2dec 8FBC8F]
    variable darkslateblue [hex2dec 483D8B]
    variable darkslategray [hex2dec 2F4F4F]
    variable darkslategrey [hex2dec 2F4F4F]
    variable darkturquoise [hex2dec 00CED1]
    variable darkviolet [hex2dec 9400D3]
    variable deeppink [hex2dec FF1493]
    variable deepskyblue [hex2dec 00BFFF]
    variable dimgray [hex2dec 696969]
    variable dimgrey [hex2dec 696969]
    variable dodgerblue [hex2dec 1E90FF]
    variable firebrick [hex2dec B22222]
    variable floralwhite [hex2dec FFFAF0]
    variable forestgreen [hex2dec 228B22]
    variable fuchsia [hex2dec FF00FF]
    variable gainsboro [hex2dec DCDCDC]
    variable ghostwhite [hex2dec F8F8FF]
    variable gold [hex2dec FFD700]
    variable goldenrod [hex2dec DAA520]
    variable gray [hex2dec 808080]
    variable green [hex2dec 008000]
    variable greenyellow [hex2dec ADFF2F]
    variable grey [hex2dec 808080]
    variable honeydew [hex2dec F0FFF0]
    variable hotpink [hex2dec FF69B4]
    variable indianred [hex2dec CD5C5C]
    variable indigo [hex2dec 4B0082]
    variable ivory [hex2dec FFFFF0]
    variable khaki [hex2dec F0E68C]
    variable lavender [hex2dec E6E6FA]
    variable lavenderblush [hex2dec FFF0F5]
    variable lawngreen [hex2dec 7CFC00]
    variable lemonchiffon [hex2dec FFFACD]
    variable lightblue [hex2dec ADD8E6]
    variable lightcoral [hex2dec F08080]
    variable lightcyan [hex2dec E0FFFF]
    variable lightgoldenrodyellow [hex2dec FAFAD2]
    variable lightgray [hex2dec D3D3D3]
    variable lightgreen [hex2dec 90EE90]
    variable lightgrey [hex2dec D3D3D3]
    variable lightpink [hex2dec FFB6C1]
    variable lightsalmon [hex2dec FFA07A]
    variable lightseagreen [hex2dec 20B2AA]
    variable lightskyblue [hex2dec 87CEFA]
    variable lightslategray [hex2dec 778899]
    variable lightslategrey [hex2dec 778899]
    variable lightsteelblue [hex2dec B0C4DE]
    variable lightyellow [hex2dec FFFFE0]
    variable lime [hex2dec 00FF00]
    variable limegreen [hex2dec 32CD32]
    variable linen [hex2dec FAF0E6]
    variable magenta [hex2dec FF00FF]
    variable maroon [hex2dec 800000]
    variable mediumaquamarine [hex2dec 66CDAA]
    variable mediumblue [hex2dec 0000CD]
    variable mediumorchid [hex2dec BA55D3]
    variable mediumpurple [hex2dec 9370DB]
    variable mediumseagreen [hex2dec 3CB371]
    variable mediumslateblue [hex2dec 7B68EE]
    variable mediumspringgreen [hex2dec 00FA9A]
    variable mediumturquoise [hex2dec 48D1CC]
    variable mediumvioletred [hex2dec C71585]
    variable midnightblue [hex2dec 191970]
    variable mintcream [hex2dec F5FFFA]
    variable mistyrose [hex2dec FFE4E1]
    variable moccasin [hex2dec FFE4B5]
    variable navajowhite [hex2dec FFDEAD]
    variable navy [hex2dec 000080]
    variable oldlace [hex2dec FDF5E6]
    variable olive [hex2dec 808000]
    variable olivedrab [hex2dec 6B8E23]
    variable orange [hex2dec FFA500]
    variable orangered [hex2dec FF4500]
    variable orchid [hex2dec DA70D6]
    variable palegoldenrod [hex2dec EEE8AA]
    variable palegreen [hex2dec 98FB98]
    variable paleturquoise [hex2dec AFEEEE]
    variable palevioletred [hex2dec DB7093]
    variable papayawhip [hex2dec FFEFD5]
    variable peachpuff [hex2dec FFDAB9]
    variable peru [hex2dec CD853F]
    variable pink [hex2dec FFC0CB]
    variable plum [hex2dec DDA0DD]
    variable powderblue [hex2dec B0E0E6]
    variable purple [hex2dec 800080]
    variable rebeccapurple [hex2dec 663399]
    variable red [hex2dec FF0000]
    variable rosybrown [hex2dec BC8F8F]
    variable royalblue [hex2dec 4169E1]
    variable saddlebrown [hex2dec 8B4513]
    variable salmon [hex2dec FA8072]
    variable sandybrown [hex2dec F4A460]
    variable seagreen [hex2dec 2E8B57]
    variable seashell [hex2dec FFF5EE]
    variable sienna [hex2dec A0522D]
    variable silver [hex2dec C0C0C0]
    variable skyblue [hex2dec 87CEEB]
    variable slateblue [hex2dec 6A5ACD]
    variable slategray [hex2dec 708090]
    variable slategrey [hex2dec 708090]
    variable snow [hex2dec FFFAFA]
    variable springgreen [hex2dec 00FF7F]
    variable steelblue [hex2dec 4682B4]
    variable tan [hex2dec D2B48C]
    variable teal [hex2dec 008080]
    variable thistle [hex2dec D8BFD8]
    variable tomato [hex2dec FF6347]
    variable turquoise [hex2dec 40E0D0]
    variable violet [hex2dec EE82EE]
    variable wheat [hex2dec F5DEB3]
    variable white [hex2dec FFFFFF]
    variable whitesmoke [hex2dec F5F5F5]
    variable yellow [hex2dec FFFF00]
    variable yellowgreen [hex2dec 9ACD32]

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
        expr {[string is integer $color] ? $color : [set Display::$color]}
    }
    proc fillTriangle {p0 p1 p2 color} {
        fillTriangleImpl [vec2i $p0] [vec2i $p1] [vec2i $p2] [getColor $color]
    }
    proc stroke {points width color} {
        for {set i 0} {$i < [llength $points]} {incr i} {
            set a [lindex $points $i]
            set b [lindex $points [expr $i+1]]
            if {$b == ""} break

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
        }
    }

    proc text {fb x y fontSize text radians} {
        drawText [expr {int($x)}] [expr {int($y)}] [expr {abs($radians) < 1.57}] $text
    }
    proc circle {x y radius thickness color} {
        for {set i 0} {$i < $thickness} {incr i} {
            drawCircle [expr {int($x)}] [expr {int($y)}] [expr {int($radius+$i)}] [getColor $color]
        }
    }
    proc image {x y im} {
        drawImage [expr {int($x)}] [expr {int($y)}] $im
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
        # fillRectangle 400 400 410 410 $Display::red ;# t0
        # fillRectangle 500 500 510 510 $Display::red ;# t1
        # fillRectangle 400 600 410 610 $Display::red ;# t2
        
        drawText 309 400 "B" 0
        drawText 318 400 "O" 0

        drawCircle 100 100 500 $Display::red

        Display::circle 300 420 400 5 blue
        Display::text fb 300 420 PLACEHOLDER "Hello!" 0

        puts [time Display::commit]
    }
}
