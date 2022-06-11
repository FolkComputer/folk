package require Thread
package require critcl
critcl::tcl 8.6

critcl::ccode {
    #include <stdatomic.h>
    atomic_int abort = 0;
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

critcl::cproc getAbortPointer {} atomic_int* { return &abort; }

set th [thread::create [format {
    package require critcl
    critcl::ccode {
        #include <stdatomic.h>
        atomic_int* abort = %s;
    }
    critcl::cproc cspin {} void {
        printf("cstart\n");
        while (!*abort) {}
        printf("cend\n");
    }

    puts tclstart
    catch {cspin}
    puts tclend
} [getAbortPointer]]]

critcl::cproc cancel {} void {
    abort = 1;
}

puts $th
after 2000 {
    cancel
}

vwait forever
