source "pi/cUtils.tcl"

namespace eval AprilTags {
    rename [c create] apc
    apc cflags -I$::env(HOME)/apriltag
    apc include <apriltag.h>
    apc include <tagStandard52h13.h>
    apc include <math.h>
    apc include <assert.h>
    apc code {
        apriltag_detector_t *td;
        apriltag_family_t *tf;
    }
    defineImageType apc
    defineFolkImages apc

    apc proc detectInit {} void {
        folkImagesMount();
        td = apriltag_detector_create();
        tf = tagStandard52h13_create();
        apriltag_detector_add_family_bits(td, tf, 1);
        td->nthreads = 2;
    }

    apc proc detect {image_t gray} Tcl_Obj* {
        assert(gray.components == 1);
        image_u8_t im = (image_u8_t) { .width = gray.width, .height = gray.height, .stride = gray.width, .buf = gray.data };
    
        zarray_t *detections = apriltag_detector_detect(td, &im);
        int detectionCount = zarray_size(detections);

        Tcl_Obj* detectionObjs[detectionCount];
        for (int i = 0; i < detectionCount; i++) {
            apriltag_detection_t *det;
            zarray_get(detections, i, &det);

            int size = sqrt((det->p[0][0] - det->p[1][0])*(det->p[0][0] - det->p[1][0]) + (det->p[0][1] - det->p[1][1])*(det->p[0][1] - det->p[1][1]));
            detectionObjs[i] = Tcl_ObjPrintf("id %d center {%f %f} corners {{%f %f} {%f %f} {%f %f} {%f %f}} size %d",
                                             det->id,
                                             det->c[0], det->c[1],
                                             det->p[0][0], det->p[0][1],
                                             det->p[1][0], det->p[1][1],
                                             det->p[2][0], det->p[2][1],
                                             det->p[3][0], det->p[3][1],
                                             size);
        }
        

        zarray_destroy(detections);
        Tcl_Obj* result = Tcl_NewListObj(detectionCount, detectionObjs);
        return result;
    }

    apc proc detectCleanup {} void {
        tagStandard52h13_destroy(tf);
        apriltag_detector_destroy(td);
    }

    c loadlib $::env(HOME)/apriltag/libapriltag.so
    apc compile
    
    proc init {} {
        detectInit
    }
}
