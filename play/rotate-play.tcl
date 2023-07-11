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
$cc proc shearX {image_t sprite int x0 int y0 int width int height double sx} void {
    for (int y = y0; y < height; y++) {
        int shear = sx * (y - y0); // May be negative.
        memmove(&sprite.data[y*sprite.bytesPerRow + (x0 + shear)*sprite.components],
                &sprite.data[y*sprite.bytesPerRow + x0*sprite.components],
                width * sprite.components);

        // Blot out the unsheared part
        if (shear > 0) {
            memset(&sprite.data[y*sprite.bytesPerRow + x0*sprite.components],
                   0x11, shear*sprite.components);
        } else if (shear < 0) {
            memset(&sprite.data[y*sprite.bytesPerRow + (x0+width+shear)*sprite.components],
                   0x11, -shear*sprite.components);
        }
    }
}
$cc proc shearY {image_t sprite int x0 int y0 int width int height double sy} void {
    for (int y = y0 + height - 1; y >= y0; y--) {
        for (int x = x0; x < x0 + width; x++) {
            int shear = sy * (x - x0); (void)shear;
            int from = y*sprite.bytesPerRow + x*sprite.components;
            int to = (y + shear)*sprite.bytesPerRow + x*sprite.components;
            sprite.data[to] = sprite.data[from];
            // Blot out the unsheared part
            if (shear > 0) sprite.data[from] = 0x11;
        }
    }
}
$cc proc rotate {image_t sprite int x0 int y0 int width int height double radians} void {
    // In-place rotation. Sprite must be big enough to accommodate the
    // rotation.
    double alpha = -tan(radians/2);
    double beta = sin(radians);
    printf("alpha = %f; beta = %f\n", alpha, beta);

    shearX(sprite, x0, y0, width, height, alpha);
    if (alpha < 0) x0 += alpha*height;
    width += fabs(alpha)*height;

    shearY(sprite, x0, y0, width, height, beta);
    if (beta < 0) y0 += beta*width;
    height += fabs(beta)*width;

    shearX(sprite, x0, y0, width, height, alpha);
}
$cc proc drawText {int x0 int y0 double radians int scale char* text} void {
    // Draws 1 line of text (no linebreak handling).
    int len = strlen(text);

    // First, render into an offscreen buffer.

    int textWidth = len * font.char_width;
    int textHeight = font.char_height;

    double alpha = -tan(radians/2);
    double beta = sin(radians);
    printf("alpha = %f (%d -> %d); beta = %f (%d -> %d)\n",
           alpha, textWidth, textWidth + (int)(alpha * textHeight),
           beta, textHeight, textHeight + (int)(beta * textWidth));

    image_t temp = {
        .width = textWidth + fabs(alpha)*textHeight*2,
        .height = textHeight + fabs(beta)*textWidth,
        .components = 1,
        .bytesPerRow = textWidth + fabs(alpha)*textHeight*2,
    };
    temp.data = ckalloc(temp.bytesPerRow * temp.height);
    memset(temp.data, 64, temp.bytesPerRow * temp.height);

    int textX = alpha > 0 ? 0 : fabs(alpha)*textHeight*2;
    int textY = beta > 0 ? 0 : fabs(beta)*textWidth;
    for (unsigned i = 0; i < len; i++) {
	int letterOffset = text[i] * font.char_height * 2;

	// Loop over the font bitmap
	for (unsigned y = 0; y < font.char_height; y++) {
	    for (unsigned x = 0; x < font.char_width; x++) {

		// Index into bitmap for pixel
		int idx = letterOffset + (y * 2) + (x >= 8 ? 1 : 0);
		int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
		if (!bit) continue;

		temp.data[(textY+y)*temp.bytesPerRow + (textX+x+i*font.char_width)*temp.components] = 0xFF;
	    }
	}
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
drawText 20 20 [degrees 80] 1 "hello"
commit
