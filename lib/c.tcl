# lib/c.tcl --
#
#     Implements the C 'FFI' that lets you embed arbitrary C/C++ code
#     into a Tcl program. Especially useful for calling existing C
#     APIs and libraries (i.e., almost anything involving hardware or
#     the OS -- graphics, webcams, multithreading). Shells out to the
#     C compiler to build a shared library and then uses Tcl "load" to
#     load it immediately.
#
# Copyright (c) 2022-2024 Folk Computer, Inc.

# Much like "subst", but you invoke a Tcl fn with $[whatever] instead
# of [whatever], so that the [] syntax is freed up to be used for C
# arrays as in normal C.
fn csubst {s} {
    set result [list]
    for {set i 0} {$i < [string length $s]} {incr i} {
        set c [string index $s $i]
        switch -- $c {
            "\\" {
                incr i; set next [string index $s $i]
                # TODO: This is a hack to deal with \n and \0.
                if {$next eq "n" || $next eq "0"} { lappend result "\\" }
                lappend result $next
            }
            {$} {
                set tail [string range $s [+ $i 1] end]
                if {[regexp {^((?:[A-Za-z0-9_]|::)+)} $tail match-> varname] ||
                    [regexp {^\{([^\}]*)\}} $tail match-> varname]} {

                    lappend result [uplevel [list set $varname]]
                    incr i [string length ${match->}]
                } elseif {[string index $tail 0] eq "\["} {
                    set bracketcount 0
                    for {set j 0} {$j < [string length $tail]} {incr j} {
                        set ch [string index $tail $j]
                        if {$ch eq "\["} { incr bracketcount } \
                        elseif {$ch eq "]"} { incr bracketcount -1 }
                        if {$bracketcount == 0} { break }
                    }
                    set script [string range $tail 1 [- $j 1]]
                    lappend result [uplevel $script]
                    incr i [expr {$j+1}]
                }
            }
            default {lappend result $c}
        }
    }
    join $result ""
}
fn cstyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $type -> basetype arraysuffix]} {
        list $basetype $name$arraysuffix
    } else {
        list $type $name
    }
}
fn typestyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $name -> basename arraysuffix]} {
        list $type$arraysuffix $basename
    } else {
        list $type $name
    }
}

set C {
    compiler cc
    prelude {
        #include <jim.h>
        #include <libzicl.h>
        #include <inttypes.h>
        #include <stdint.h>
        #include <stdbool.h>
        #include <stdio.h>
        #include <setjmp.h>
        #include "folk-zicl.h"

        #if __has_include ("tracy/TracyC.h")
        #include "tracy/TracyC.h"
        #endif

        extern __thread Jim_Interp* interp;
        extern __thread jmp_buf __onError;
        extern __thread bool __onErrorIsSet;

        #define __ENSURE(EXPR) if (!(EXPR)) { Jim_SetResultFormatted(interp, "failed to convert argument from Tcl to C in: " #EXPR); longjmp(__onError, 0); }
        #define __ENSURE_OK(EXPR) if ((EXPR) != JIM_OK) { longjmp(__onError, 0); }

        #define FOLK_ERROR(...) do { \
            char __msg[1024]; snprintf(__msg, 1024, ##__VA_ARGS__); \
            Jim_SetResultString(interp, __msg, -1); \
            longjmp(__onError, 0); \
          } while (0)
        #define FOLK_ABORT() longjmp(__onError, 0)
        #define FOLK_ENSURE(EXPR) if (!(EXPR)) { Jim_SetResultString(interp, "assertion failed: " #EXPR, -1); longjmp(__onError, 0); }
        #define FOLK_CHECK(EXPR, MSG) if (!(EXPR)) { FOLK_ERROR(MSG); }
    }
    code {}

    vars {}
    procs {}

    objtypes {}

    extends {}

    ___argtypes_comment {
        # Tcl->C conversion logic, when a value is passed from Tcl
        # to a C function as an argument.
    }
    argtypes {
        int { identity { long _$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_$argname)); int $argname = (int)_$argname; }}
        double { identity { double $argname; __ENSURE_OK(Zicl_GetDouble(interp, $shim, &$argname)); }}
        float { identity { double _$argname; __ENSURE_OK(Zicl_GetDouble(interp, $shim, &_$argname)); float $argname = (float)_$argname; }}
        bool { identity { int _$argname; __ENSURE_OK(Zicl_GetBoolean(interp, $shim, &_$argname)); bool $argname = !!_$argname; }}
        int32_t { identity { long _$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_$argname)); int32_t $argname = (int)_$argname; }}
        char { identity {
            char $argname;
            {
                int _len_$argname;
                char* _tmp_$argname = ziclShimGetString($shim, &_len_$argname);
                __ENSURE(_len_$argname >= 1);
                $argname = _tmp_$argname[0];
            }
        }}
        size_t { identity { size_t $argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, (long *)&$argname)); }}
        intptr_t { identity { intptr_t $argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, (long *)&$argname)); }}
        uint16_t { identity { uint16_t $argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, (int *)&$argname)); }}
        uint32_t { identity { uint32_t $argname; __ENSURE(sscanf(ziclShimString($shim), "%" PRIu32, &$argname) == 1); }}
        uint64_t { identity { uint64_t $argname; __ENSURE(sscanf(ziclShimString($shim), "%" PRIu64, &$argname) == 1); }}
        char* { identity { char* $argname = (char*) ziclShimString($shim); } }
        Zicl_Value { identity { Zicl_Value $argname = Zicl_Current($shim); }}
        default {
            if {[string index $argtype end] == "*"} {
                set basetype [string range $argtype 0 end-1]
                error "Need to port this to the capability framework"
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                # note: arraylen can be ""
                if {$basetype eq "char"} { identity {
                    int $[set argname]_len; const char *$[set argname]_bytes = ziclShimString($shim, &len);
                    if ($[set argname]_len > $arraylen) $[set argname]_len = $arraylen;
                    char $argname[$arraylen]; memcpy($argname, $[set argname]_bytes, $[set argname]_len);
                } } else { identity {
                    const Zicl_List *$[set argname]_list = __ENSURE(Zicl_ListShimmer(interp, $shim, &$[set argname]_list));
                    int $[set argname]_objc = Zicl_ListLength($[set argname]_list);
                    const Zicl_Value *$[set argname]_objv = Zicl_ListItems($[set argname]_list);
                    $basetype $argname[$[set argname]_objc];
                    {
                        for (int i = 0; i < $[set argname]_objc; i++) {
                            Zicl_Shimmerable $[set argname]_shim = Zicl_NewShimmerable($[set argname]_objv[i]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim); }
                            $[self::arg $basetype ${argname}_i "&$[set argname]_shim"]
                            $argname[i] = $[set argname]_i;
                        }
                    }
                } }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $argtype -> basetype arraylen arraylen2]} {
                identity {
                    const Zicl_List *$[set argname]_list_2 = __ENSURE(Zicl_ListShimmer(interp, $shim, &$[set argname]_list_2));
                    int $[set argname]_objc_2 = Zicl_ListLength($[set argname]_list_2);
                    const Zicl_Value *$[set argname]_objv_2 = Zicl_ListItems($[set argname]_list_2);
                    $basetype $argname[$[set argname]_objc_2][$arraylen2];
                    {
                        for (int j = 0; j < $[set argname]_objc_2; j++) {
                            Zicl_Shimmerable $[set argname]_shim_2 = Zicl_NewShimmerable($[set argname]_objv_2[j]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim_2); }
                            $[self::arg $basetype\[\] ${argname}_j "&$[set argname]_shim_2"]
                            memcpy(${argname}[j], ${argname}_j, sizeof(${argname}_j));
                        }
                    }
                }
            } else {
                error "Unrecognized argtype $argtype"
            }
        }
    }

    ___rtypes_comment {
        # C->Tcl conversion logic, when a value is returned from a
        # C function to Tcl.
    }
    rtypes {
        int { identity { $robj = Zicl_NewInt($rvalue); }}
        int32_t { identity { $robj = Zicl_NewInt($rvalue); }}
        double { identity { $robj = Zicl_NewInt($rvalue); }}
        float { identity { $robj = Zicl_NewInt($rvalue); }}
        char { identity { $robj = ziclNewString(&$rvalue, 1); }}
        bool { identity { $robj = Zicl_NewInt($rvalue); }}
        uint8_t { identity { $robj = Zicl_NewInt($rvalue); }}
        uint16_t { identity { $robj = Zicl_NewInt($rvalue); }}
        uint32_t { identity { $robj = Zicl_NewInt($rvalue); }}
        uint64_t { identity { $robj = Zicl_NewInt((uint64_t)($rvalue)); }}
        size_t { identity { $robj = Zicl_NewInt($rvalue); }}
        intptr_t { identity { $robj = Zicl_NewInt($rvalue); }}
        char* { identity { $robj = ziclNewString($rvalue, -1); } }
        Zicl_Value { identity { $robj = $rvalue; }}
        default {
            if {[string index $rtype end] == "*"} {
                identity { $robj = ziclValuePrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue); }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                if {$basetype eq "char"} { identity {
                    $robj = ziclValuePrintf($rvalue);
                } } else { identity {
                    {
                        Zicl_Value objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $[self::ret $basetype objv\[i\] $rvalue\[i\]]
                        }
                        $robj = Zicl_BoxList(ziclNewList(objv, $arraylen));
                    }
                } }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $rtype -> basetype arraylen arraylen2]} { identity {
                    {
                        Zicl_Value objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $basetype* rrow = $rvalue[i];
                            Zicl_Value* objrow = &objv[i];
                            $[self::ret ${basetype}\[${arraylen2}\] *objrow rrow]
                        }
                        $robj = Zicl_BoxList(ziclNewList(objv, $arraylen));
                    }
            } } else {
                error "Unrecognized rtype $rtype"
            }
        }
    }

    cflags {-I./vendor/jimtcl -I./vendor/zicl/zig-out/include -I./}
    endcflags {}

    cfile {}

    ___addrs_comment {
        # Used to store function pointers so you can import them
        # across modules.
    }
    addrs {}
}

# Registers a new argtype.
method C::argtype {self t h} {
    dict set argtypes $t [csubst {identity {$h}}]
}
# Looks up the argtype and returns C code to convert it.
method C::arg {self argtype argname shim} {
    csubst [eval [dict getdef $self::argtypes $argtype \
                      [dict get $self::argtypes default]]]
}

# Registers a new rtype.
method C::rtype {self t h} {
    dict set rtypes $t [csubst {identity {$h}}]
}
method C::ret {self rtype robj rvalue} {
    csubst [eval [dict getdef $self::rtypes $rtype \
                      [dict get $self::rtypes default]]]
}

method C::include {self h} {
    if {[llength $h] > 1} {
        lappend self::code $h :extend
        return
    }

    if {[string index $h 0] eq "<"} {
        lappend self::code "#include $h" :extend
    } else {
        lappend self::code "#include \"$h\"" :extend
    }
}

method C::addcode {self newcode} {
    lassign [info source $newcode] filename line
    if {$filename ne ""} { 
        set newcode [subst {
            $newcode
        }]
    }
    lappend code $newcode :noextend
    list
}

method C::define {self newvars} {
    lappend code $newvars :noextend

    regsub -all -line {/\*.*?\*/} $newvars "" newvars
    regsub -all -line {//.*$} $newvars "" newvars
    regsub -all {=[^;]*;} $newvars "" newvars
    set newvars [string map {";" ""} $newvars]

    foreach {vartype varname} $newvars {
        if {[dict exists $vars $varname]} {
            error "var already exists: $varname"
        }
        dict set vars $varname $vartype

        lappend code [subst {
            $vartype *${varname}_ptr() {
                return &$varname;
            }
        }] :noextend
    }
}

method C::enum {self type values} {
    lappend self::code [subst {
        typedef enum $type $type;
        enum $type {$values};
    }] :extend

    regsub -all {,} $values "" values
    argtype $type [dict get $argtypes int]
    rtype $type [dict get $self::rtypes int]
}

method C::typedef {self t newt {emitC true}} {
    if {$emitC} {
        lappend self::code "typedef $t $newt;" :extend
    }
    set argtype $t; set rtype $t

    # We suppress the errors because you often just use typedef for
    # opaque pointers where c.tcl doesn't know the actual struct
    # definition.
    try {
        self::argtype $newt [eval [dict getdef $argtypes $argtype \
                                       [dict get $argtypes default]]]
    } on error e {
        # puts stderr "C typedef: $e"
    }
    try {
        self::rtype $newt [eval [dict getdef $self::rtypes $rtype \
                                     [dict get $self::rtypes default]]]
    } on error e {
        # puts stderr "C typedef: $e"
    }
}

method C::struct {self type fields} {
    lappend self::code [subst {
        typedef struct $type $type;
        struct $type {$fields};
    }] :extend

    regsub -all -line {/\*.*?\*/} $fields "" fields
    regsub -all -line {//.*$} $fields "" fields
    if {[regsub -all {\s_Atomic\s} $fields " " fields] > 0} {
        puts stderr "C struct $type: Warning: Will ignore _Atomic for getters and setters"
    }
    set fields [string map {";" ""} $fields]

    set fieldnames [list]
    for {set i 0} {$i < [llength $fields]} {incr i 2} {
        set fieldtype [lindex $fields $i]
        set fieldname [lindex $fields $i+1]
        lassign [typestyle $fieldtype $fieldname] fieldtype fieldname
        lappend fieldnames $fieldname
        lset fields $i $fieldtype
        lset fields $i+1 $fieldname
    }

    self::include <string.h>
    # ptrAndLongRep.value = 1 means the data is owned by
    # the Jim_ObjType and should be freed by this
    # code. value = 0 means the data is owned externally
    # (by someone else like the statement store).
    dict set objtypes $type [csubst {
        $[join [lmap fieldname $fieldnames { subst {
            __thread Zicl_Value k__${type}__${fieldname} = NULL;
        } }] "\n"]
        Jim_ObjType* $[set type]_ObjType;

        void $[set type]_freeIntRepProc(Jim_Interp* interp, Zicl_Value objPtr) {
            if (objPtr->internalRep.ptrIntValue.int1 == 1) {
                free((char*)objPtr->internalRep.ptrIntValue.ptr);
            }
        }
        void $[set type]_dupIntRepProc(Jim_Interp* interp, Zicl_Value srcPtr, Zicl_Value dupPtr) {
            dupPtr->internalRep.ptrIntValue.ptr = malloc(sizeof($type));
            dupPtr->internalRep.ptrIntValue.int1 = 1;
            memcpy(dupPtr->internalRep.ptrIntValue.ptr, srcPtr->internalRep.ptrIntValue.ptr, sizeof($type));
        }
        void $[set type]_updateStringProc(Zicl_Value objPtr) {
            $[set type] *robj = ($[set type] *) objPtr->internalRep.ptrIntValue.ptr;

            const char *format = "$[join [lmap fieldname $fieldnames {
                subst {$fieldname {%s}}
                }] { }]";
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_Value robj_$fieldname;
                    $[self::ret $fieldtype robj_$fieldname robj->$fieldname]
                }
            }] "\n"]
            objPtr->length = snprintf(NULL, 0, format, $[join [lmap fieldname $fieldnames {subst {Jim_String(robj_$fieldname)}}] ", "]);
            objPtr->bytes = (char *) Jim_Alloc(objPtr->length + 1);
            snprintf(objPtr->bytes, objPtr->length + 1, format, $[join [lmap fieldname $fieldnames {subst {Jim_String(robj_$fieldname)}}] ", "]);
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Jim_FreeNewObj(interp, robj_$fieldname);
                }
            }] "\n"]
        }
        int $[set type]_setFromAnyProc(Jim_Interp *interp, Zicl_Value objPtr) {
            if (objPtr->typePtr == $[set type]_ObjType) { return JIM_OK; }

            $[set type] *robj = ($[set type] *)malloc(sizeof($[set type]));
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_Value obj_$fieldname;
                    if (k__$[set type]__$fieldname == NULL) {
                        k__${type}__${fieldname} = Jim_NewStringObj(interp, "$fieldname", -1);
                        Jim_IncrRefCount(k__${type}__${fieldname});
                    }
                    __ENSURE_OK(Jim_DictKey(interp, objPtr, k__$[set type]__$fieldname, &obj_$fieldname, JIM_ERRMSG));

                    $[self::arg $fieldtype robj_$fieldname obj_${fieldname}]
                    memcpy(&robj->$fieldname, &robj_$fieldname, sizeof(robj->$fieldname));
                }
            }] "\n"]

            Jim_FreeIntRep(interp, objPtr);
            objPtr->typePtr = $[set type]_ObjType;
            objPtr->internalRep.ptrIntValue.ptr = robj;
            objPtr->internalRep.ptrIntValue.int1 = 1;
            return JIM_OK;
        }

        void $[set type]_init(Jim_Interp* interp, const char* cid) {
            $[set type]_ObjType = malloc(sizeof(Jim_ObjType));
            *$[set type]_ObjType = (Jim_ObjType) {
                .name = "$type",
                .freeIntRepProc = $[set type]_freeIntRepProc,
                .dupIntRepProc = $[set type]_dupIntRepProc,
                .updateStringProc = $[set type]_updateStringProc
                // .setFromAnyProc = $[set type]_setFromAnyProc
            };

            char script[1000];
            snprintf(script, 1000,
                     "dict set {::<C:%s> __addrs} $[set type]_setFromAnyProc %p\n"
                     "dict set {::<C:%s> __addrs} $[set type]_ObjType %p",
                     cid, &$[set type]_setFromAnyProc,
                     cid, $[set type]_ObjType);
            Jim_Eval(interp, script);
        }
    }]

    self::argtype $type [csubst {
        __ENSURE_OK($[set type]_setFromAnyProc(interp, \$obj));
        \$argtype \$argname;
        \$argname = *(($type *)\$obj->internalRep.ptrIntValue.ptr);
    }]

    self::rtype $type {
        $robj = Jim_NewObj(interp);
        $robj->bytes = NULL;
        $robj->typePtr = $[set rtype]_ObjType;
        $robj->internalRep.ptrIntValue.ptr = malloc(sizeof($[set rtype]));
        $robj->internalRep.ptrIntValue.int1 = 1;
        memcpy($robj->internalRep.ptrIntValue.ptr, &$rvalue, sizeof($[set rtype]));
    }

    # Generate Tcl getter functions for each field:
    set ns [uplevel {namespace current}]::$type
    namespace eval $ns {}
    foreach {fieldtype fieldname} $fields {
        try {
            if {$fieldtype ne "Zicl_Value" &&
                [regexp {(^[^\[]+)(?:\[(\d*)\]|\*)(?:\[(\d+)\])?$} $fieldtype -> basefieldtype arraylen arraylen2]} {
                if {$basefieldtype eq "char"} {
                    self::proc ${type}_$fieldname {Jim_Interp* interp Zicl_Value obj} char* {
                        __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                        return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                    }
                } else {
                    if {$arraylen2 eq ""} {
                        self::proc ${type}_${fieldname}_ptr {Jim_Interp* interp Zicl_Value obj} $basefieldtype* {
                            __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                            return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                        }
                        set elementtype $basefieldtype
                    } else {
                        set elementtype $basefieldtype\[$arraylen2\]
                    }
                    # If fieldtype is a pointer or an array,
                    # then make a getter that takes an index.
                    self::proc ${type}_$fieldname {Jim_Interp* interp Zicl_Value obj int idx} $elementtype {
                        __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                        return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname[idx];
                    }
                }
            } else {
                self::proc ${type}_$fieldname {Jim_Interp* interp Zicl_Value obj} $fieldtype {
                    __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                    return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                }
            }
        } on error e {
            puts stderr "Warning: Unable to generate getter for `$type $fieldname`: $e"
        }
    }
    namespace eval $ns {
        namespace export *
        namespace ensemble create
    }
}

method C::proc {self name arguments rtype body} {
    set cname [string map {":" "_" "!" "_"} $name]
    lassign [info source $body] filename line
    set body [uplevel 1 [list csubst $body]]

    set arglist [list]
    set argnames [list]
    set loadargs [list]
    foreach {argtype argname} $arguments {
        lassign [typestyle $argtype $argname] argtype argname
        lappend arglist [join [cstyle $argtype $argname] " "]
        lappend argnames $argname

        if {$argtype eq "Zicl_Interp*" && $argname eq "interp"} { continue }

        set obj [subst {objv\[1 + [llength $loadargs]\]}]
        set res [typestyle $argtype $argname]
        lappend loadargs [self::arg {*}$res $obj]
    }
    regsub {\[\d*\]} $rtype * decayedRtype
    if {$rtype eq "void"} {
        set saverv [subst {
            $cname ([join $argnames ", "]);
        }]
    } else {
        set saverv [subst {
            $decayedRtype rvalue = $cname ([join $argnames ", "]);
            Zicl_Value* robj;
            [self::ret $rtype robj rvalue]
            Zicl_SetResultOwning(interp, robj);
        }]
    }

    if {[dict exists $self::procs $name]} { error "C proc: Name collision: $name" }
    dict set self::procs $name rtype $rtype
    dict set self::procs $name arglist $arglist
    dict set self::procs $name code [subst {
        static $decayedRtype $cname ([join $arglist ", "]) {
            [if {$filename ne ""} {
                subst {}
            } else {list}]
            $body
        }

        static int [set cname]_Cmd(Zicl_Interp* interp, int objc, Zicl_Value* objv\[\]) {
            if (objc != 1 + [llength $loadargs]) {
                Zicl_SetResultString(interp, "Wrong number of arguments to $name", -1);
                return JIM_ERR;
            }
            bool didSetOnError = false;
            if (!__onErrorIsSet) {
                int __r = setjmp(__onError);
                __onErrorIsSet = true;
                didSetOnError = true;

                if (__r != 0) {
                    __onErrorIsSet = false;
                    return JIM_ERR;
                }
            }

            [join $loadargs "\n"]
            $saverv

            if (didSetOnError) {
                __onErrorIsSet = false;
            }
            return JIM_OK;
        }
    }]
}

method C::addcflags {self args} { lappend self::cflags {*}$args }
method C::addendcflags {self args} { lappend self::endcflags {*}$args }

method C::compile {self args} {
    set noload false
    set cid {}
    foreach arg $args {
        if {$arg eq "-noload"} {
            set noload true
        } else {
            set cid $arg
        }
    }
    set cfile [file tempfile /tmp/cfileXXXXXX].c

    # A universally unique id that can be used as a global proc name
    # in every thread.
    if {$cid eq {}} {
        set cid [file rootname [file tail $cfile]]
    }

    set init [subst {
        #include <string.h>

        #ifdef __cplusplus
        \}
        #include <atomic>
        static std::atomic<const char*> __cInfo(nullptr);
        extern "C" \{
        #else
        static const char* _Atomic __cInfo = NULL;
        #endif

        static int __setCInfo_Cmd(Zicl_Interp *interp, int objc, Zicl_Shimmerable *const objv\[\]) {
            if (__cInfo != NULL || objc != 2) { return ZICL_USAGE; }
            const char* cInfo = Zicl_ShimString(objv\[1\]);
            if (cInfo == NULL) { return ZICL_OOM; }
            __cInfo = strdup(cInfo);
            return ZICL_OK;
        }
        static __thread Zicl_Value __cInfoValue = NULL;
        static int __getCInfo_Cmd(Jim_Interp* interp, int objc, Zicl_Shimmerable *const objv\[\]) {
            if (__cInfo == NULL || objc != 1) { return ZICL_USAGE; }
            if (__cInfoValue == NULL) {
                __cInfoValue = folkNewString(__cInfo, -1);
            }
            Jim_SetResult(interp, __cInfoValue);
            return JIM_OK;
        }

        int Jim_${cid}Init(Jim_Interp* intp) {
            interp = intp;

            [join [lmap srcid $self::extends {
                subst {Jim_${srcid}Init(interp);}
            }] "\n"]

            Jim_CreateCommand(interp, "<C:$cid> __setCInfo", __setCInfo_Cmd, NULL, NULL);
            Jim_CreateCommand(interp, "<C:$cid> __getCInfo", __getCInfo_Cmd, NULL, NULL);

            [join [lmap varname [dict keys $self::vars] {
                csubst {{
                    char script[1000];
                    snprintf(script, 1000, "dict set {::<C:$cid> __addrs} ${varname}_ptr %p", &${varname}_ptr);
                    Jim_Eval(interp, script);
                }}
            }] "\n"]

            [join [lmap name [dict keys $self::procs] {
                set cname [string map {":" "_" "!" "_"} $name]
                set tclname $name
                # puts "Creating C command: $tclname"
                csubst {{
                    char script[1000];
                    snprintf(script, 1000, "dict set {::<C:$cid> __addrs} $cname %p", $cname);
                    Jim_Eval(interp, script);

                    Jim_CreateCommand(interp, "<C:$cid> $tclname", $[set cname]_Cmd, NULL, NULL);
                }}
            }] "\n"]

            {
                char script\[1000\];
                snprintf(script, 1000, "dict set {::<C:$cid> __addrs} Jim_${cid}Init %p", Jim_${cid}Init);
                Jim_Eval(interp, script);
            }

            [join [lmap type [dict keys $self::objtypes] { subst {
                ${type}_init(interp, "$cid");
            } }] "\n"]
            return JIM_OK;
        }
    }]
    set externC [subst {
#ifdef __cplusplus
extern "C" \{
#endif
}]
    set unexternC [subst {
#ifdef __cplusplus
\}
#endif
}]
    set sourcecode [join [list \
                              $externC \
                              $self::prelude \
                              $unexternC \
                              \
                              {*}[lmap {snippet extend} $self::code {set snippet}] \
                              \
                              $externC \
                              {*}[dict values $self::objtypes] \
                              {*}[lmap p [dict values $self::procs] {dict get $p code}] \
                              $init \
                              $unexternC \
                             ] "\n"]

    # puts "=====================\n$sourcecode\n====================="

    set cfd [fopen $cfile w]; puts $cfd $sourcecode; close $cfd
    set ignoreUnresolved {}; if {$tcl_platform::os eq "linux"} {
        set ignoreUnresolved -Wl,--unresolved-symbols=ignore-all
    } elseif {$tcl_platform::os eq "darwin"} {
        set ignoreUnresolved -Wl,-undefined,dynamic_lookup
    }
    if {[__isTracyEnabled]} {
        lappend self::cflags -DTRACY_ENABLE=1 -I./vendor/tracy/public
    }
    set asan_flags {}
    if {[info exists env::ASAN_ENABLE] && $env::ASAN_ENABLE != ""} {
        set asan_flags "-fsanitize=address -fsanitize-recover=address"
    }
    puts [list [list $self::compiler {*}$asan_flags -Wall \
                        {*}$($tcl_platform::os eq "linux" ? [list -Wno-alloc-size-larger-than] : [list]) \
                        -U_FORTIFY_SOURCE -O2 -march=native -g \
                        -fno-omit-frame-pointer -fPIC \
                        {*}$self::cflags $cfile -c -o [file rootname $cfile].o]]
    puts "\n"
    set out [exec [list $self::compiler {*}$asan_flags -Wall \
                        {*}$($tcl_platform::os eq "linux" ? [list -Wno-alloc-size-larger-than] : [list]) \
                        -U_FORTIFY_SOURCE -O2 -march=native -g \
                        -fno-omit-frame-pointer -fPIC \
                        {*}$self::cflags $cfile -c -o [file rootname $cfile].o]]
    if {[string trim $out] ne ""} {
        puts $out
    }

    # HACK: Why do we need this / only when running in lldb?
    set n 0
    while {![file exists [file rootname $cfile].o]} {
        sleep 0.01
        incr n
        if {$n > 1000} { error "Failed on $cfile! Timed out" }
    }

    exec $self::compiler {*}$asan_flags -shared $ignoreUnresolved \
        -O2 -o /tmp/$cid.so [file rootname $cfile].o \
        {*}$self::endcflags

    # HACK: Why do we need this / only when running in lldb?
    set n 0
    while {![file exists /tmp/$cid.so]} {
        sleep 0.01
        incr n
        if {$n > 10} { error "Failed! [string range $e 0 500]" }
    }

    if {$noload} {
        # Return the name of the compiled file instead of loading it.
        return /tmp/$cid.so
    }

    set cInfo [dict create]
    foreach varName [self::vars] {
        dict set cInfo $varName [self::get $varName]
    }
    
    # Load the compiled module immediately so we can set its C info.
    <C:$cid>
    <C:$cid> __setCInfo $cInfo

    return <C:$cid>
}

method C::import {self srclib srcname {_as {}} {destname {}}} {
    if {$destname eq ""} { set destname $srcname }

    set procinfo [dict get [$srclib __getCInfo] procs $srcname]
    set rtype [dict get $procinfo rtype]
    set arglist [dict get $procinfo arglist]

    set addr [dict get [set "::$srclib __addrs"] $srcname]
    self::addcode "$rtype (*$destname) ([join $arglist {, }]) = ($rtype (*) ([join $arglist {, }])) $addr;"
}

method C::string_toupper_first {self s} {
    return [string toupper [string index $s 0]][string range $s 1 end]
}
method C::extend {self args} {
    set noprocs false
    foreach arg $args {
        if {$arg eq "-noprocs"} {
            set noprocs true
        } else {
            set srclib $arg
        }
    }
    set srcinfo [$srclib __getCInfo]
    set srcaddrs [set "::$srclib __addrs"]

    foreach {snippet extend} [dict get $srcinfo code] {
        if {$extend eq ":extend"} {
            lappend code $snippet :noextend
        }
    }

    set argtypes [dict merge [dict get $srcinfo argtypes] $argtypes]
    set rtypes [dict merge [dict get $srcinfo rtypes] $self::rtypes]
    dict for {objtype _} [dict get $srcinfo objtypes] {
        self::addcode "int (*${objtype}_setFromAnyProc)(Jim_Interp *interp, Zicl_Value objPtr) = \
(int (*)(Jim_Interp *interp, Zicl_Value objPtr)) \
[dict get $srcaddrs ${objtype}_setFromAnyProc];"
        self::addcode "Jim_ObjType* ${objtype}_ObjType = (Jim_ObjType*) [dict get $srcaddrs ${objtype}_ObjType];"
    }

    if {!$noprocs} {
        foreach procName [dict keys [dict get $srcinfo procs]] {
            self::import $srclib $procName
        }
    }

    dict for {varname vartype} [dict get $srcinfo vars] {
        set addr [dict get $srcaddrs ${varname}_ptr]
        self::addcode "$vartype* (*${varname}_ptr)() = ($vartype* (*)()) $addr;"
    }

    regexp {<C:([^ ]+)>} $srclib -> srcid
    set addr [dict get $srcaddrs Jim_${srcid}Init]
    self::addcode "int (*Jim_${srcid}Init)(Jim_Interp* intp) =
                     (int (*)(Jim_Interp* intp)) $addr;"

    lappend extends $srcid
}

fn C++ {} {
    set cpp [C]
    $cpp eval [list set compiler c++]
    $cpp addcflags -Wno-write-strings
    return $cpp
}
