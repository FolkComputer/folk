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

$cc proc drawText {int x0 int y0 double radians int scale char* text} void {
    // Draws 1 line of text (no linebreak handling).
    int len = strlen(text);

    for (unsigned i = 0; i < len; i++) {
	int letterOffset = text[i] * font.char_height * 2;

	// Loop over the font bitmap
	for (unsigned y = 0; y < font.char_height; y++) {
	    for (unsigned x = 0; x < font.char_width; x++) {

		// Index into bitmap for pixel
		int idx = letterOffset + (y * 2) + (x >= 8 ? 1 : 0);
		int bit = (font.font_bitmap[idx] >> (7 - (x & 7))) & 0x01;
		if (!bit) continue;

		buffer[(y0+y)*fbwidth + (x0+x+i*font.char_width)] = 0xFFFF;
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
