source "lib/c.tcl"
source "pi/cUtils.tcl"

rename [c create] dc
set cc dc
$cc cflags -I/Users/osnr/aux/minifb/include /Users/osnr/aux/minifb/build/libminifb.a -framework Cocoa -framework Metal -framework MetalKit

$cc include <stdlib.h>
$cc include <string.h>
$cc include <math.h>
$cc include "MiniFB.h"

$cc code [source "vendor/font.tcl"]

$cc code {
    struct mfb_window* window;
    uint32_t* staging;

    int fbwidth = 800;
    int fbheight = 600;

    typedef uint32_t pixel_t;
    #define PIXEL_R(pixel) (((pixel) >> 16) | 0xFF)
    #define PIXEL_G(pixel) (((pixel) >> 8) | 0xFF)
    #define PIXEL_B(pixel) (((pixel) >> 0) | 0xFF)
    #define PIXEL(r, g, b) (((r) << 16) | ((g) << 8) | ((b) << 0))
}
$cc proc init {} void {
    window = mfb_open_ex("my display", 800, 600, WF_RESIZABLE);
    if (!window) return;

    staging = (uint32_t*) malloc(800 * 600 * 4);
}

defineImageType $cc
$cc proc drawImage {int x0 int y0 image_t image int scale} void {
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
source "pi/rotate.tcl"
$cc proc drawText {int x0 int y0 double radians int scale char* text} void {
    // Draws text (breaking at linebreaks), with the center of the
    // text at (x0, y0). Rotates by radians with the anchor at (x0,
    // y0).

    int len = strlen(text);
    if (fabs(radians) > M_PI/2) {
        printf("Bad\n");
    }

    // First, render into an offscreen buffer.

    int textWidth = 0;
    int textHeight = font.char_height;
    int lineWidth = 0;
    for (unsigned i = 0; i < len; i++) {
        if (text[i] == '\n') {
            lineWidth = 0;
            textHeight += font.char_height;
        } else {
            lineWidth += font.char_width;
            if (lineWidth > textWidth) { textWidth = lineWidth; }
        }
    }

    double alpha = -tan(-radians/2);
    double beta = sin(-radians);

    image_t temp; {
        temp.width = textWidth; 
        temp.height = textHeight;

        temp.width += fabs(alpha)*temp.height;
        temp.height += fabs(beta)*temp.width;
        temp.width += fabs(alpha)*temp.height;

        temp.components = 1;
        temp.bytesPerRow = temp.width * temp.components;
        temp.data = ckalloc(temp.bytesPerRow * temp.height);
        memset(temp.data, 64, temp.bytesPerRow * temp.height);
    }

    int textX = alpha > 0 ? 0 : temp.width - textWidth;
    int textY = beta > 0 ? 0 : temp.height - textHeight;
    int x = textX; int y = textY;
    for (unsigned i = 0; i < len; i++) {
        if (text[i] == '\n') {
            x = textX;
            y += font.char_height;
            continue;
        }
        int letterOffset = text[i] * font.char_height * 2;

        // Loop over the font bitmap
        for (unsigned ypix = 0; ypix < font.char_height; ypix++) {
            for (unsigned xpix = 0; xpix < font.char_width; xpix++) {

                // Index into bitmap for pixel
                int idx = letterOffset + (ypix * 2) + (xpix >= 8 ? 1 : 0);
                int bit = (font.font_bitmap[idx] >> (7 - (xpix & 7))) & 0x01;
                if (!bit) continue;

                temp.data[(y+ypix)*temp.bytesPerRow +
                          (x+xpix)*temp.components] = 0xFF;
            }
        }
        x += font.char_width;
    }

    rotate(temp, textX, textY, textWidth, textHeight, radians);

    for (int x = 0; x < temp.width; x++) {
        temp.data[x] = 0xFF;
        temp.data[x + (temp.height - 1)*temp.bytesPerRow] = 0xFF;
    }
    for (int y = 0; y < temp.height; y++) {
        temp.data[y*temp.bytesPerRow] = 0xFF;
        temp.data[y*temp.bytesPerRow + temp.width - 1] = 0xFF;
    }

    drawImage(x0, y0, temp, scale);
    ckfree(temp.data);
}

$cc proc commit {} void {
    do {
        int state;
        state = mfb_update_ex(window, staging, 800, 600);

        if (state < 0) {
            window = NULL;
            break;
        }
    } while(mfb_wait_sync(window));
}

$cc compile

proc degrees {deg} { expr {$deg/180.0 * 3.14159} }

init
drawText 20 20 [degrees 133] 1 "hello"
commit
