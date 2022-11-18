if {[namespace exists critcl]} {
    critcl::ccode {
        #define _GNU_SOURCE
        #include <unistd.h>
    }
    critcl::cproc getTid {} int {
        return gettid();
    }
} elseif {[namespace exists c]} {
    set handle [c create]
    $handle include <sys/syscall.h>
    $handle include <unistd.h>
    $handle proc getTid {} int {
        return syscall(SYS_gettid);
    }
    $handle compile
}

proc opaquePointerType {type} {
    critcl::ccode {
        #include <inttypes.h>
    }
    critcl::argtype $type [subst -nobackslashes {
        sscanf(Tcl_GetString(@@), "($type) 0x%p", &@A);
    }] $type

    critcl::resulttype $type [subst -nobackslashes {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("($type) 0x%" PRIxPTR, (uintptr_t) rv));
        return TCL_OK;
    }] $type
}

proc defineImageType {cc} {
    $cc code {
        typedef struct {
            uint32_t width;
            uint32_t height;
            int components;
            size_t bytesPerRow;

            uint8_t *data;
        } image_t;
    }

    $cc argtype image_t {
        sscanf(Tcl_GetString($obj), "width %u height %u components %d bytesPerRow %lu data 0x%p", &$argname.width, &$argname.height, &$argname.components, &$argname.bytesPerRow, &$argname.data);
    }
    $cc rtype image_t {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("width %u height %u components %d bytesPerRow %lu data 0x%" PRIxPTR, rv.width, rv.height, rv.components, rv.bytesPerRow, (uintptr_t) rv.data));
        return TCL_OK;
    }

    uplevel { namespace eval image {
        proc width {im} { dict get $im width }
        proc height {im} { dict get $im height }
        namespace export *
        namespace ensemble create
    } }
}
