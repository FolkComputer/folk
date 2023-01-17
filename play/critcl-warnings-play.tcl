package require critcl

critcl::cflags -Werror -Wall
critcl::tcl 8.6

proc opaquePointerType {type} {
    critcl::argtype $type "
        sscanf(Tcl_GetString(@@), \"($type) 0x%p\", &@A);
    " $type

    critcl::resulttype $type "
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(\"($type) 0x%x\", (size_t) rv));
        return TCL_OK;
    " $type
}

critcl::ccode {
    #include <stdlib.h>

    typedef struct {
        int x;
    } whump_t;
}
opaquePointerType whump_t*

critcl::cproc hello {} whump_t* {
    whump_t* w = malloc(sizeof(whump_t));
    w->x = 301;
    return w;
}

critcl::clean_cache 
critcl::config keepsrc true

puts [hello]
