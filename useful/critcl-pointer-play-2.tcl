package require critcl

proc opaquePointerType {type} {
    critcl::argtype $type "
        sscanf(Tcl_GetString(@@), \"($type) 0x%p\", &@A);
    " $type

    critcl::resulttype $type "
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(\"($type) 0x%x\", (size_t) rv));
        return TCL_OK;
    " $type
}
opaquePointerType void*

critcl::cproc hello {} void* {
    char* hello = "Hello";
    return hello;
}
critcl::cproc print {void* ptr} void {
    printf("text: [%s]\n", ptr);
}

puts [hello]
print [hello]
