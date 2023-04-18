dc code {
#include <stdbool.h>

typedef int OutCode;

const int INSIDE = 0; // 0000
const int LEFT = 1;   // 0001
const int RIGHT = 2;  // 0010
const int BOTTOM = 4; // 0100
const int TOP = 8;    // 1000

// Compute the bit code for a point (x, y) using the clip rectangle
// bounded diagonally by (xmin, ymin), and (xmax, ymax)

// ASSUME THAT xmax, xmin, ymax and ymin are global constants.
float xmin; float xmax;
float ymin; float ymax;

OutCode ComputeOutCode(float x, float y)
{
	OutCode code = INSIDE;  // initialised as being inside of clip window

	if (x < xmin)           // to the left of clip window
		code |= LEFT;
	else if (x > xmax)      // to the right of clip window
		code |= RIGHT;
	if (y < ymin)           // below the clip window
		code |= BOTTOM;
	else if (y > ymax)      // above the clip window
		code |= TOP;

	return code;
}

// Cohen–Sutherland clipping algorithm clips a line from
// P0 = (x0, y0) to P1 = (x1, y1) against a rectangle with 
// diagonal from (xmin, ymin) to (xmax, ymax).
bool CohenSutherlandLineClip(float* x0_, float* y0_, float* x1_, float* y1_)
{
    float x0 = *x0_; float y0 = *y0_; float x1 = *x1_; float y1 = *y1_;

	// compute outcodes for P0, P1, and whatever point lies outside the clip rectangle
	OutCode outcode0 = ComputeOutCode(x0, y0);
	OutCode outcode1 = ComputeOutCode(x1, y1);
	int accept = false;

	while (true) {
		if (!(outcode0 | outcode1)) {
			// bitwise OR is 0: both points inside window; trivially accept and exit loop
			accept = true;
			break;
		} else if (outcode0 & outcode1) {
			// bitwise AND is not 0: both points share an outside zone (LEFT, RIGHT, TOP,
			// or BOTTOM), so both must be outside window; exit loop (accept is false)
			break;
		} else {
			// failed both tests, so calculate the line segment to clip
			// from an outside point to an intersection with clip edge
			float x, y;

			// At least one endpoint is outside the clip rectangle; pick it.
			OutCode outcodeOut = outcode1 > outcode0 ? outcode1 : outcode0;

			// Now find the intersection point;
			// use formulas:
			//   slope = (y1 - y0) / (x1 - x0)
			//   x = x0 + (1 / slope) * (ym - y0), where ym is ymin or ymax
			//   y = y0 + slope * (xm - x0), where xm is xmin or xmax
			// No need to worry about divide-by-zero because, in each case, the
			// outcode bit being tested guarantees the denominator is non-zero
			if (outcodeOut & TOP) {           // point is above the clip window
				x = x0 + (x1 - x0) * (ymax - y0) / (y1 - y0);
				y = ymax;
			} else if (outcodeOut & BOTTOM) { // point is below the clip window
				x = x0 + (x1 - x0) * (ymin - y0) / (y1 - y0);
				y = ymin;
			} else if (outcodeOut & RIGHT) {  // point is to the right of clip window
				y = y0 + (y1 - y0) * (xmax - x0) / (x1 - x0);
				x = xmax;
			} else if (outcodeOut & LEFT) {   // point is to the left of clip window
				y = y0 + (y1 - y0) * (xmin - x0) / (x1 - x0);
				x = xmin;
			}

			// Now we move outside point to intersection point to clip
			// and get ready for next pass.
			if (outcodeOut == outcode0) {
				x0 = x;
				y0 = y;
				outcode0 = ComputeOutCode(x0, y0);
			} else {
				x1 = x;
				y1 = y;
				outcode1 = ComputeOutCode(x1, y1);
			}
		}
	}
    *x0_ = x0; *y0_ = y0; *x1_ = x1; *y1_ = y1;
	return accept;
}
}

dc proc clipLine {Tcl_Interp* interp Tcl_Obj* aVar Tcl_Obj* bVar int width} void {
    // has some margin to account for nudge
    xmin = width + 1; xmax = fbwidth - 1 - width - 1; // TODO: do this just once at boot
    ymin = width + 1; ymax = fbheight - 1 - width - 1;

    float x0; float x1; float y0; float y1;
    sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, aVar, NULL, 0)), "%f %f", &x0, &y0);
    sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, bVar, NULL, 0)), "%f %f", &x1, &y1);
    CohenSutherlandLineClip(&x0, &y0, &x1, &y1);

    Tcl_ObjSetVar2(interp, aVar, NULL, Tcl_ObjPrintf("%d %d", (int)x0, (int)y0), 0);
    Tcl_ObjSetVar2(interp, bVar, NULL, Tcl_ObjPrintf("%d %d", (int)x1, (int)y1), 0);
}
