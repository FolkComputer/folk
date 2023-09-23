source "pi/cUtils.tcl"

package require TclOO
namespace import oo::*
catch {AprilTags destroy}

class create AprilTags {
    constructor {TAG_FAMILY} {
        my variable cc
        set cc [c create]

        $cc cflags -I$::env(HOME)/apriltag $::env(HOME)/apriltag/libapriltag.a
        $cc include <apriltag.h>
        $cc include <$TAG_FAMILY.h>
        $cc include <math.h>
        $cc include <assert.h>
        $cc code {
            apriltag_detector_t *td;
            apriltag_family_t *tf;
        }
        ::defineImageType $cc

        $cc proc detectInit {} void [csubst {
            td = apriltag_detector_create();
            tf = ${TAG_FAMILY}_create();
            apriltag_detector_add_family_bits(td, tf, 1);
            td->nthreads = 2;
        }]
        $cc proc detectImpl {image_t gray} Tcl_Obj* {
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
        $cc proc detectCleanup {} void [csubst {
            ${TAG_FAMILY}_destroy(tf);
            apriltag_detector_destroy(td);
        }]

        c loadlib $::env(HOME)/apriltag/libapriltag.so
        $cc compile
        detectInit
    }
    method detect {image} { detectImpl $image }
}
