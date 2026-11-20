// Minimal C shim over libapriltag for ctypes-based simulation.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "apriltag.h"
#include "tagStandard52h13.h"
#include "common/image_u8.h"
#include "common/zarray.h"

static apriltag_family_t *fam = NULL;

apriltag_detector_t *shim_detector_create(float quad_decimate, int nthreads) {
    if (!fam) fam = tagStandard52h13_create();
    apriltag_detector_t *td = apriltag_detector_create();
    apriltag_detector_add_family_bits(td, fam, 3);
    td->quad_decimate = quad_decimate;
    td->nthreads = nthreads;
    return td;
}

void shim_detector_destroy(apriltag_detector_t *td) {
    apriltag_detector_destroy(td);
}

int shim_family_total_width(void) {
    if (!fam) fam = tagStandard52h13_create();
    return fam->total_width;
}
int shim_family_width_at_border(void) {
    if (!fam) fam = tagStandard52h13_create();
    return fam->width_at_border;
}
int shim_family_ncodes(void) {
    if (!fam) fam = tagStandard52h13_create();
    return fam->ncodes;
}

// Render the tag bitmap (total_width x total_width, values 0/255) into out.
// Returns total_width.
int shim_render_tag(uint32_t idx, uint8_t *out) {
    if (!fam) fam = tagStandard52h13_create();
    image_u8_t *im = apriltag_to_image(fam, idx);
    int w = im->width;
    for (int y = 0; y < w; y++) {
        memcpy(out + y * w, im->buf + y * im->stride, w);
    }
    image_u8_destroy(im);
    return w;
}

// Detect tags in a width x height grayscale image (row stride = width).
// Writes up to maxdets detections into out as [id, hamming, margin,
// cx, cy, p0x, p0y, p1x, p1y, p2x, p2y, p3x, p3y] doubles. Returns the
// number of detections found (may exceed maxdets; only maxdets written).
int shim_detect(apriltag_detector_t *td, uint8_t *buf, int width, int height,
                double *out, int maxdets) {
    image_u8_t im = { .width = width, .height = height, .stride = width, .buf = buf };
    zarray_t *dets = apriltag_detector_detect(td, &im);
    int n = zarray_size(dets);
    for (int i = 0; i < n && i < maxdets; i++) {
        apriltag_detection_t *det;
        zarray_get(dets, i, &det);
        double *o = out + i * 13;
        o[0] = det->id;
        o[1] = det->hamming;
        o[2] = det->decision_margin;
        o[3] = det->c[0]; o[4] = det->c[1];
        for (int k = 0; k < 4; k++) {
            o[5 + 2*k] = det->p[k][0];
            o[6 + 2*k] = det->p[k][1];
        }
    }
    apriltag_detections_destroy(dets);
    return n;
}
