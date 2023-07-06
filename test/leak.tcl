set cc [c create]
$cc code {
    Tcl_Obj* sentinel;
    bool freedSentinel = false;

    void sentinel_freeIntRepProc(Tcl_Obj *objPtr)  {
        printf("freed sentinel! %p\n", objPtr);
        freedSentinel = true;
    }
    void sentinel_dupIntRepProc(Tcl_Obj *srcPtr, Tcl_Obj *dupPtr) {}
    void sentinel_updateStringProc(Tcl_Obj *objPtr) {
        objPtr->bytes = ckalloc(10);
        objPtr->length = snprintf(objPtr->bytes, 10, "SENTINEL");
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
    sentinel = Tcl_NewObj();
    sentinel->bytes = NULL;
    sentinel->typePtr = &sentinel_ObjType;
    freedSentinel = false;
    printf("allocated sentinel %p\n", sentinel);
    return sentinel;
}
$cc proc checkIfFreedSentinel {} bool { return freedSentinel; }
$cc proc sentinelRefCount {} int { return sentinel->refCount; }
$cc compile

set x [makeSentinel]
set x none
assert [checkIfFreedSentinel]

puts -------------------------------------

Assert there is a sentinel [makeSentinel]
Step
Retract there is a sentinel /any/
Step
assert [checkIfFreedSentinel]

puts -------------------------------------

Assert A has program code {
    When the collected matches for [list /someone/ is a [makeSentinel]] are /matches/ {
        Claim ok
    }
}
Step
Retract A has program code /any/
Step
assert [checkIfFreedSentinel]
