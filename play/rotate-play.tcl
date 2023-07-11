source "lib/c.tcl"
source "pi/cUtils.tcl"

set cc [c create]
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

$cc proc drawText {int x0 int y0 double radians int scale char* text} void {
    // Draws 1 line of text (no linebreak handling).
    int len = strlen(text);

    // First, render into an offscreen buffer.

    int textWidth = len * font.char_width;
    int textHeight = font.char_height;

    float alpha = tanf(radians/2);
    float beta = sin(radians);
    printf("alpha = %f; beta = %f\n", alpha, beta);

    image_t temp = {
        .width = textWidth + textWidth * alpha,
        .height = textHeight + textHeight * beta,
        .components = 1,
        .bytesPerRow = textWidth + textWidth * alpha,
    };
    temp.data = ckalloc(temp.bytesPerRow * temp.height);
    memset(temp.data, 0, temp.bytesPerRow * temp.height);

    for (unsigned i = 0; i < len; i++) {
	int letterOffset = text[i] * font.char_height * 2;

	// Loop over the font bitmap
	for (unsigned y = 0; y < font.char_height; y++) {
	    for (unsigned x = 0; x < font.char_width; x++) {

		// Index into bitmap for pixel
		int idx = letterOffset + (y * 2) + (x >= 8 ? 1 : 0);
		int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
		if (!bit) continue;

		temp.data[y*temp.width + (x+i*font.char_width)] = 0xFF;
	    }
	}
    }

    
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

init
drawText 20 20 0 1 "hello"
commit
