package require critcl
critcl::cflags -Wall -Werror
critcl::tcl 8.6

proc opaquePointerType {type} {
    critcl::argtype $type "
        sscanf(Tcl_GetString(@@), \"($type) 0x%p\", &@A);
    " $type

    critcl::resulttype $type "
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(\"($type) 0x%lx\", (uintptr_t) rv));
        return TCL_OK;
    " $type
}
opaquePointerType void*

critcl::cproc chello {} void* {
    char* hello = "Hello";
    return hello;
}
critcl::cproc cprint {void* pointer} void {
    printf("text at pointer: [%s]\n", (char*) pointer);
}

set pointerFromC [chello]
puts "got pointer from C: $pointerFromC"
cprint $pointerFromC
