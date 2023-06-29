if {[namespace exists c] && $::tcl_platform(os) eq "Linux"} {
    set handle [c create]
    $handle include <sys/syscall.h>
    $handle include <unistd.h>
    $handle proc getTid {} int {
        return syscall(SYS_gettid);
    }
    $handle compile
}

# FIXME: this shouldn't be global
proc ::defineImageType {cc} {
    set cc [uplevel {namespace current}]::$cc
    $cc code {
        typedef struct {
            uint32_t width;
            uint32_t height;
            int components;
            uint32_t bytesPerRow;

            uint8_t *data;
        } image_t;
    }

    $cc argtype image_t {
        image_t $argname; sscanf(Tcl_GetString($obj), "width %u height %u components %d bytesPerRow %u data 0x%p", &$argname.width, &$argname.height, &$argname.components, &$argname.bytesPerRow, &$argname.data);
    }
    $cc rtype image_t {
        $robj = Tcl_ObjPrintf("width %u height %u components %d bytesPerRow %u data 0x%" PRIxPTR, $rvalue.width, $rvalue.height, $rvalue.components, $rvalue.bytesPerRow, (uintptr_t) $rvalue.data);
    }
}
