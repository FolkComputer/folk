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
