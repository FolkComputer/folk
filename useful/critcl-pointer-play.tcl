package require critcl

critcl::ccode {
    static Tcl_Obj *
    MakePointerObj(void *pointer) {
        Tcl_Obj *handle = Tcl_ObjPrintf("pointer0x%x", (size_t) pointer);
        return handle;
    }

    static int
    GetPointerFromObj(Tcl_Interp *interp, Tcl_Obj *objPtr, void **pointerPtr) {
        scanf(Tcl_GetString(objPtr), "pointer%p", pointerPtr);
        return TCL_OK;
    }
}
critcl::argtype ptr {
    GetPointerFromObj(interp, @@, @A);
} void*
critcl::resulttype ptr {
    Tcl_SetObjResult(interp, MakePointerObj(rv));
    return TCL_OK;
} void*

critcl::cproc allocate {} ptr {
    char *str = "hello";
    return (void *) str;
}
critcl::cproc printString {ptr s} void {
    printf("s [%s]\n", (char *) s);
}
printString [allocate]

# critcl::cproc test {} void {
#     char *hello = "Hello\n";
#     char out[100];
#     sprintf(out, "pointer%p", hello);
#     printf("out = [%s]\n", out);

#     void *p;
#     sscanf(out, "pointer%p", &p);
#     printf("p = %p\n", p);
#     printf("%s", (char *) p);
# }
# test
