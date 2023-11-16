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
        # In favor of this: we want to have the member getters generated in Tcl.
        # Against this:
        #  - duplicate struct defn (add a flag?)
        #  - how to free the matd_t on destruction (add destructor support?)
        # Hack for now: this is identical to apriltag_detection_t, but redefined here.
        $cc struct apriltag_detection_ffi {
            apriltag_family_t* family;
            int id;
            int hamming;
            float decision_margin;
            matd_t* H;
            double c[2];
            double p[8]; // TODO: Make 2D array.
        } ;# -nodefine -destructor
        ::defineImageType $cc

        $cc proc detectInit {} void [csubst {
            td = apriltag_detector_create();
            tf = ${TAG_FAMILY}_create();
            apriltag_detector_add_family_bits(td, tf, 1);
            td->nthreads = 2;
        }]

        # Returns a Tcl-wrapped list of AprilTag detection objects.
        $cc proc detectImpl {image_t gray} Tcl_Obj* {
            assert(gray.components == 1);
            image_u8_t im = (image_u8_t) { .width = gray.width, .height = gray.height, .stride = gray.bytesPerRow, .buf = gray.data };

            zarray_t *detections = apriltag_detector_detect(td, &im);
            int detectionCount = zarray_size(detections);

            Tcl_Obj* detectionObjs[detectionCount];
            for (int i = 0; i < detectionCount; i++) {
                apriltag_detection_ffi *det;
                zarray_get(detections, i, &det);

                // Wrap the apriltag_detection_t* in a Tcl_Obj*.
                detectionObjs[i] = Tcl_NewObj();
                detectionObjs[i]->bytes = NULL;
                detectionObjs[i]->typePtr = &apriltag_detection_ffi_ObjType;
                detectionObjs[i]->internalRep.ptrAndLongRep.ptr = det;
                // owned by us, not by Tcl.
                detectionObjs[i]->internalRep.ptrAndLongRep.value = 0;
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
