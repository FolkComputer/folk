/* Finding contours in binary images and approximating polylines.
 * Implements the same algorithms as OpenCV's findContours and approxPolyDP.
 *
 * C port of PContour.java by Lingdong Huang, originally made possible with
 * support from The Frank-Ratchye STUDIO For Creative Inquiry at Carnegie
 * Mellon University. http://studioforcreativeinquiry.org/
 *
 * Dynamic arrays come from stb_ds.h (use arrlen / arrfree on returned arrays).
 */

#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

#include "stb_ds.h"

#define N_PIXEL_NEIGHBOR 8

typedef struct {
    int x;
    int y;
} Point;

typedef struct {
    Point *points;  /* stb_ds dynamic array */
    int id;         /* unique id, starts from 2 */
    int parent;     /* id of parent contour, 0 means top-level */
    bool isHole;    /* true if this is a hole border */
} Contour;

/* Counter-clockwise neighbor offsets, indexed by neighbor id 0..7. */
static const int neighborDi[N_PIXEL_NEIGHBOR] = { 0, -1, -1, -1,  0,  1, 1, 1};
static const int neighborDj[N_PIXEL_NEIGHBOR] = { 1,  1,  0, -1, -1, -1, 0, 1};

/* Inverse of the offset tables; returns -1 if (i,j) is not in the neighborhood. */
static int neighborIndexToID(int i0, int j0, int i, int j) {
    int di = i - i0;
    int dj = j - j0;
    for (int k = 0; k < N_PIXEL_NEIGHBOR; k++) {
        if (neighborDi[k] == di && neighborDj[k] == dj) return k;
    }
    return -1;
}

/* First counter-clockwise non-zero pixel in the 8-neighborhood of (i0,j0),
 * starting the search from (i,j) + offset steps. Writes the found pixel to
 * (*outI, *outJ) and returns true; returns false if all neighbors are zero.
 */
static bool ccwNon0(const int *F, int w, int i0, int j0,
                    int i, int j, int offset,
                    int *outI, int *outJ) {
    int id = neighborIndexToID(i0, j0, i, j);
    for (int k = 0; k < N_PIXEL_NEIGHBOR; k++) {
        int kk = (k + id + offset + N_PIXEL_NEIGHBOR * 2) % N_PIXEL_NEIGHBOR;
        int ni = i0 + neighborDi[kk];
        int nj = j0 + neighborDj[kk];
        if (F[ni * w + nj] != 0) {
            *outI = ni;
            *outJ = nj;
            return true;
        }
    }
    return false;
}

/* First clockwise non-zero pixel in the 8-neighborhood (mirror of ccwNon0). */
static bool cwNon0(const int *F, int w, int i0, int j0,
                   int i, int j, int offset,
                   int *outI, int *outJ) {
    int id = neighborIndexToID(i0, j0, i, j);
    for (int k = 0; k < N_PIXEL_NEIGHBOR; k++) {
        int kk = (-k + id - offset + N_PIXEL_NEIGHBOR * 2) % N_PIXEL_NEIGHBOR;
        int ni = i0 + neighborDi[kk];
        int nj = j0 + neighborDj[kk];
        if (F[ni * w + nj] != 0) {
            *outI = ni;
            *outJ = nj;
            return true;
        }
    }
    return false;
}

/* Free a Contour array returned by findContours. */
static void freeContours(Contour *contours) {
    for (ptrdiff_t i = 0; i < arrlen(contours); i++) {
        arrfree(contours[i].points);
    }
    arrfree(contours);
}

/* Find contours in a binary image. Implements Suzuki & Abe, "Topological
 * Structural Analysis of Digitized Binary Images by Border Following",
 * CVGIP 30 1, pp 32-46 (1985).
 *
 *   F  bitmap, row-major, w*h ints. 0=background, 1=foreground. Modified
 *      in-place to hold semantic information.
 *   w, h  bitmap dimensions.
 *
 * Returns an stb_ds dynamic array of Contour. Free with freeContours().
 */
static Contour *findContours(int *F, int w, int h) {
    int nbd = 1;
    int lnbd = 1;

    Contour *contours = NULL;

    /* Without loss of generality, assume that 0-pixels fill the frame. */
    for (int i = 1; i < h - 1; i++) {
        F[i * w] = 0;
        F[i * w + w - 1] = 0;
    }
    for (int i = 0; i < w; i++) {
        F[i] = 0;
        F[w * h - 1 - i] = 0;
    }

    for (int i = 1; i < h - 1; i++) {
        lnbd = 1;

        for (int j = 1; j < w - 1; j++) {
            int i2 = 0, j2 = 0;
            if (F[i * w + j] == 0) continue;

            if (F[i * w + j] == 1 && F[i * w + (j - 1)] == 0) {
                /* (a) start of an outer border. */
                nbd++;
                i2 = i;
                j2 = j - 1;
            } else if (F[i * w + j] >= 1 && F[i * w + j + 1] == 0) {
                /* (b) start of a hole border. */
                nbd++;
                i2 = i;
                j2 = j + 1;
                if (F[i * w + j] > 1) lnbd = F[i * w + j];
            } else {
                /* (c) not a border start: resume the raster scan. */
                if (F[i * w + j] != 1) lnbd = abs(F[i * w + j]);
                continue;
            }

            /* (2) decide the parent of the new border. */
            Contour B = {
                .points = NULL,
                .id = nbd,
                .parent = 0,
                .isHole = (j2 == j + 1),
            };
            Point start = { j, i };
            arrput(B.points, start);
            arrput(contours, B);

            Contour B0 = { 0 };
            for (ptrdiff_t c = 0; c < arrlen(contours); c++) {
                if (contours[c].id == lnbd) {
                    B0 = contours[c];
                    break;
                }
            }
            Contour *curr = &contours[arrlen(contours) - 1];
            if (B0.isHole) {
                curr->parent = curr->isHole ? B0.parent : lnbd;
            } else {
                curr->parent = curr->isHole ? lnbd : B0.parent;
            }

            /* (3.1) starting from (i2,j2), look clockwise for a non-zero pixel. */
            int i1, j1;
            if (!cwNon0(F, w, i, j, i2, j2, 0, &i1, &j1)) {
                F[i * w + j] = -nbd;
                if (F[i * w + j] != 1) lnbd = abs(F[i * w + j]);
                continue;
            }

            /* (3.2) */
            i2 = i1;
            j2 = j1;
            int i3 = i;
            int j3 = j;

            for (;;) {
                /* (3.3) examine ccw neighbors of (i3,j3) starting after (i2,j2). */
                int i4, j4;
                ccwNon0(F, w, i3, j3, i2, j2, 1, &i4, &j4);

                Point p = { j4, i4 };
                arrput(contours[arrlen(contours) - 1].points, p);

                if (F[i3 * w + j3 + 1] == 0) {
                    /* (3.4a) */
                    F[i3 * w + j3] = -nbd;
                } else if (F[i3 * w + j3] == 1) {
                    /* (3.4b) */
                    F[i3 * w + j3] = nbd;
                }
                /* (3.4c) otherwise unchanged */

                /* (3.5) */
                if (i4 == i && j4 == j && i3 == i1 && j3 == j1) {
                    if (F[i * w + j] != 1) lnbd = abs(F[i * w + j]);
                    break;
                }
                i2 = i3;
                j2 = j3;
                i3 = i4;
                j3 = j4;
            }
        }
    }
    return contours;
}

static float pointDistanceToSegment(Point p, Point p0, Point p1) {
    /* https://stackoverflow.com/a/6853926 */
    float x = p.x, y = p.y;
    float x1 = p0.x, y1 = p0.y;
    float x2 = p1.x, y2 = p1.y;
    float A = x - x1, B = y - y1, C = x2 - x1, D = y2 - y1;
    float dot = A * C + B * D;
    float lenSq = C * C + D * D;
    float param = (lenSq != 0) ? dot / lenSq : -1.0f;

    float xx, yy;
    if (param < 0) {
        xx = x1; yy = y1;
    } else if (param > 1) {
        xx = x2; yy = y2;
    } else {
        xx = x1 + param * C;
        yy = y1 + param * D;
    }
    float dx = x - xx, dy = y - yy;
    return sqrtf(dx * dx + dy * dy);
}

/* Simplify contour by removing definitely extraneous vertices. Returns a new
 * stb_ds dynamic array; caller frees with arrfree(). */
static Point *approxPolySimple(const Point *polyline) {
    const float epsilon = 0.1f;
    ptrdiff_t n = arrlen(polyline);
    Point *ret = NULL;
    if (n <= 2) {
        arrsetlen(ret, n);
        for (ptrdiff_t i = 0; i < n; i++) ret[i] = polyline[i];
        return ret;
    }
    arrput(ret, polyline[0]);
    for (ptrdiff_t i = 1; i < n - 1; i++) {
        float d = pointDistanceToSegment(polyline[i],
                                         polyline[i - 1],
                                         polyline[i + 1]);
        if (d > epsilon) arrput(ret, polyline[i]);
    }
    arrput(ret, polyline[n - 1]);
    return ret;
}

/* Ramer-Douglas-Peucker on the slice [lo, hi) of polyline. Appends the kept
 * points of the slice (excluding the last one) to *out. */
static void approxPolyDPRecurse(const Point *polyline, ptrdiff_t lo,
                                ptrdiff_t hi, float epsilon, Point **out) {
    ptrdiff_t n = hi - lo;
    if (n <= 2) {
        if (n >= 1) arrput(*out, polyline[lo]);
        return;
    }
    float dmax = 0;
    ptrdiff_t argmax = -1;
    for (ptrdiff_t i = lo + 1; i < hi - 1; i++) {
        float d = pointDistanceToSegment(polyline[i],
                                         polyline[lo],
                                         polyline[hi - 1]);
        if (d > dmax) {
            dmax = d;
            argmax = i;
        }
    }
    if (dmax > epsilon) {
        approxPolyDPRecurse(polyline, lo, argmax + 1, epsilon, out);
        approxPolyDPRecurse(polyline, argmax, hi, epsilon, out);
    } else {
        arrput(*out, polyline[lo]);
    }
}

/* Simplify contour using the Ramer-Douglas-Peucker algorithm. Returns a new
 * stb_ds dynamic array; caller frees with arrfree(). */
static Point *approxPolyDP(const Point *polyline, float epsilon) {
    ptrdiff_t n = arrlen(polyline);
    Point *ret = NULL;
    if (n <= 2) {
        arrsetlen(ret, n);
        for (ptrdiff_t i = 0; i < n; i++) ret[i] = polyline[i];
        return ret;
    }
    approxPolyDPRecurse(polyline, 0, n, epsilon, &ret);
    arrput(ret, polyline[n - 1]);
    return ret;
}
