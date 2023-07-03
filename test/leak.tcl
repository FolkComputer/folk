set cc [c create]
$cc code {
    bool freedSentinel = false;

    void sentinel_freeIntRepProc(Tcl_Obj *objPtr)  {
        printf("freed sentinel!\n");
        freedSentinel = true;
    }
    void sentinel_dupIntRepProc(Tcl_Obj *srcPtr, Tcl_Obj *dupPtr) {}
    void sentinel_updateStringProc(Tcl_Obj *objPtr) {
        objPtr->bytes = ckalloc(10);
        objPtr->length = snprintf(objPtr->bytes, 10, "sentinel");
    }
    int sentinel_setFromAnyProc(Tcl_Interp *interp, Tcl_Obj *objPtr) {
        return TCL_ERROR;
    }
    Tcl_ObjType sentinel_ObjType = (Tcl_ObjType) {
        .name = "sentinel",
        .freeIntRepProc = sentinel_freeIntRepProc,
        .dupIntRepProc = sentinel_dupIntRepProc,
        .updateStringProc = sentinel_updateStringProc,
        .setFromAnyProc = sentinel_setFromAnyProc
    };
}
$cc proc makeSentinel {} Tcl_Obj* {
    Tcl_Obj* ret = Tcl_NewObj();
    ret->bytes = NULL;
    ret->typePtr = &sentinel_ObjType;
    return ret;
}
$cc proc checkIfFreedSentinel {} bool { return freedSentinel; }
$cc proc resetFreedSentinel {} void { freedSentinel = false; }
$cc compile

set x [makeSentinel]
set x none
assert [checkIfFreedSentinel]

resetFreedSentinel; puts -------------------------------------

Assert there is a sentinel [makeSentinel]
Step
Retract there is a sentinel /any/
Step
assert [checkIfFreedSentinel]
