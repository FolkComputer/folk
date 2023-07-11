source "lib/c.tcl"

set cc [c create]
$cc cflags -I/Users/osnr/aux/minifb/include /Users/osnr/aux/minifb/build/libminifb.a -framework Cocoa -framework Metal -framework MetalKit

$cc include <stdlib.h>
$cc include <string.h>
$cc include "MiniFB.h"

$cc code [source "vendor/font.tcl"]

$cc code {
    struct mfb_window* window;
    uint32_t* buffer;

    int fbwidth = 800;
    int fbheight = 600;
}
$cc proc init {} void {
    window = mfb_open_ex("my display", 800, 600, WF_RESIZABLE);
    if (!window) return;

    buffer = (uint32_t*) malloc(800 * 600 * 4);
}

$cc proc drawText {int x0 int y0 int upsidedown int scale char* text} void {
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

			buffer[sy*fbwidth + sx] = 0xFFFF;
		    }
		}
	    }
	}
    }
}

$cc proc commit {} void {
    do {
        int state;
        state = mfb_update_ex(window, buffer, 800, 600);

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
