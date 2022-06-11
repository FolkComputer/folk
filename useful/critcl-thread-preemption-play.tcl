package require Thread
package require critcl
critcl::tcl 8.6
critcl::cflags -Wall -Werror

critcl::ccode {
    #include <stdatomic.h>
    atomic_int die = 0;
}
proc opaquePointerType {type} {
    critcl::argtype $type "
        sscanf(Tcl_GetString(@@), \"($type) 0x%p\", &@A);
    " $type

    critcl::resulttype $type "
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(\"($type) 0x%x\", (size_t) rv));
        return TCL_OK;
    " $type
}
opaquePointerType atomic_int*

critcl::cproc getDiePointer {} atomic_int* { return &die; }
critcl::cproc cancel {} void {
    die = 1;
}

set th [thread::create [format {
    package require critcl
    critcl::ccode {
        #include <stdatomic.h>
        atomic_int* die = %s;
    }
    critcl::cproc cspin {} void {
        printf("cstart\n");
        while (!*die) {}
        printf("cend\n");
    }

    puts tclstart
    catch {cspin}
    puts tclend
} [getDiePointer]]]


puts $th
after 2000 {
    cancel
}

vwait forever
