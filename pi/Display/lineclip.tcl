dc code {
typedef int OutCode;

const int INSIDE = 0; // 0000
const int LEFT = 1;   // 0001
const int RIGHT = 2;  // 0010
const int BOTTOM = 4; // 0100
const int TOP = 8;    // 1000

// Compute the bit code for a point (x, y) using the clip rectangle
// bounded diagonally by (xmin, ymin), and (xmax, ymax)

// ASSUME THAT xmax, xmin, ymax and ymin are global constants.

// (osnr: now using 0/0/fbwidth/fbheight instead of xmin/ymin/xmax/ymax)

OutCode ComputeOutCode(double x, double y)
{
	OutCode code = INSIDE;  // initialised as being inside of clip window

	if (x < 0)           // to the left of clip window
		code |= LEFT;
	else if (x > fbwidth)      // to the right of clip window
		code |= RIGHT;
	if (y < 0)           // below the clip window
		code |= BOTTOM;
	else if (y > fbheight)      // above the clip window
		code |= TOP;

	return code;
}

// Cohen–Sutherland clipping algorithm clips a line from
// P0 = (x0, y0) to P1 = (x1, y1) against a rectangle with 
// diagonal from (xmin, ymin) to (xmax, ymax).
bool CohenSutherlandLineClip(double& x0, double& y0, double& x1, double& y1)
{
	// compute outcodes for P0, P1, and whatever point lies outside the clip rectangle
	OutCode outcode0 = ComputeOutCode(x0, y0);
	OutCode outcode1 = ComputeOutCode(x1, y1);
	int accept = 0;

	while (true) {
		if (!(outcode0 | outcode1)) {
			// bitwise OR is 0: both points inside window; trivially accept and exit loop
			accept = 1;
			break;
		} else if (outcode0 & outcode1) {
			// bitwise AND is not 0: both points share an outside zone (LEFT, RIGHT, TOP,
			// or BOTTOM), so both must be outside window; exit loop (accept is false)
			break;
		} else {
			// failed both tests, so calculate the line segment to clip
			// from an outside point to an intersection with clip edge
			double x, y;

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
	return accept;
}
}

dc proc clipLine {Tcl_Obj* aVar Tcl_Obj* bVar} void {
    double x0; double x1; double y0; double y1;
    sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, aVar, NULL, 0)), "%f %f", &x0, &y0);
    sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, bVar, NULL, 0)), "%f %f", &x1, &y1);
    CohenSutherlandLineClip(x0, y0, x1, y1);

    Tcl_ObjSetVar2(interp, aVar, NULL, Tcl_ObjPrintf("%d %d", (int)x0, (int)y0));
    Tcl_ObjSetVar2(interp, bVar, NULL, Tcl_ObjPrintf("%d %d", (int)x1, (int)y1));
}
