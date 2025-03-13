# lib/c.tcl --
#
#     Implements the C 'FFI' that lets you embed arbitrary C/C++ code
#     into a Tcl program. Especially useful for calling existing C
#     APIs and libraries (i.e., almost anything involving hardware or
#     the OS -- graphics, webcams, multithreading). Shells out to the
#     C compiler to build a shared library and then uses Tcl `load` to
#     load it immediately.
#
# Copyright (c) 2022-2024 Folk Computer, Inc.

# Much like `subst`, but you invoke a Tcl fn with $[whatever] instead
# of [whatever], so that the [] syntax is freed up to be used for C
# arrays as in normal C.
proc csubst {s} {
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
                set tail [string range $s $i+1 end]
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
                    set script [string range $tail 1 $j-1]
                    lappend result [uplevel $script]
                    incr i [expr {$j+1}]
                }
            }
            default {lappend result $c}
        }
    }
    join $result ""
}
::proc cstyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $type -> basetype arraysuffix]} {
        list $basetype $name$arraysuffix
    } else {
        list $type $name
    }
}
::proc typestyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $name -> basename arraysuffix]} {
        list $type$arraysuffix $basename
    } else {
        list $type $name
    }
}

package require oo

class C {
    compiler cc
    prelude {
        #include <jim.h>
        #include <inttypes.h>
        #include <stdint.h>
        #include <stdbool.h>
        #include <stdio.h>
        #include <setjmp.h>

        static __thread jmp_buf __onError;
        static __thread Jim_Interp* interp;

        #define __ENSURE(EXPR) if (!(EXPR)) { Jim_SetResultFormatted(interp, "failed to convert argument from Tcl to C in: " #EXPR); longjmp(__onError, 0); }
        #define __ENSURE_OK(EXPR) if ((EXPR) != JIM_OK) { longjmp(__onError, 0); }

        #define FOLK_ERROR(...) do { \
            char msg[1024]; snprintf(msg, 1024, ##__VA_ARGS__); \
            Jim_SetResultString(interp, msg, -1); \
            longjmp(__onError, 0); \
          } while (0)
        #define FOLK_ENSURE(EXPR) if (!(EXPR)) { Jim_SetResultString(interp, "assertion failed: " #EXPR, -1); longjmp(__onError, 0); }
        #define FOLK_CHECK(EXPR, MSG) if (!(EXPR)) { FOLK_ERROR(MSG); }

        Jim_Obj* Jim_ObjPrintf(const char* format, ...) {
            va_list args;
            va_start(args, format);
            char buf[10000]; vsnprintf(buf, 10000, format, args);
            va_end(args);
            return Jim_NewStringObj(interp, buf, -1);
        }
    }
    code {}

    vars {}
    procs {}

    objtypes {}

    ___argtypes_comment {
        # Tcl->C conversion logic, when a value is passed from Tcl
        # to a C function as an argument.
    }
    argtypes {
        int { expr {{ long _$argname; __ENSURE_OK(Jim_GetLong(interp, $obj, &_$argname)); int $argname = (int)_$argname; }}}
        double { expr {{ double $argname; __ENSURE_OK(Jim_GetDouble(interp, $obj, &$argname)); }}}
        float { expr {{ double _$argname; __ENSURE_OK(Jim_GetDouble(interp, $obj, &_$argname)); float $argname = (float)_$argname; }}}
        bool { expr {{ bool $argname; __ENSURE_OK(Jim_GetBoolean(interp, $obj, &$argname)) }}}
        int32_t { expr {{ long _$argname; __ENSURE_OK(Jim_GetLong(interp, $obj, &_$argname)); int32_t $argname = (int)_$argname; }}}
        char { expr {{
            char $argname;
            {
                int _len_$argname;
                char* _tmp_$argname = Jim_GetStringFromObj($obj, &_len_$argname);
                __ENSURE(_len_$argname >= 1);
                $argname = _tmp_$argname[0];
            }
        }}}
        size_t { expr {{ size_t $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, (long *)&$argname)); }}}
        intptr_t { expr {{ intptr_t $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, (long *)&$argname)); }}}
        uint16_t { expr {{ uint16_t $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, (int *)&$argname)); }}}
        uint32_t { expr {{ uint32_t $argname; __ENSURE(sscanf(Jim_String($obj), "%" PRIu32, &$argname) == 1); }}}
        uint64_t { expr {{ uint64_t $argname; __ENSURE(sscanf(Jim_String($obj), "%" PRIu64, &$argname) == 1); }}}
        char* { expr {{ char* $argname = (char*) Jim_String($obj); }} }
        Jim_Obj* { expr {{ Jim_Obj* $argname = $obj; }}}
        default {
            if {[string index $argtype end] == "*"} {
                set basetype [string range $argtype 0 end-1]
                if {[dict exists $argtypes $basetype]} {
                    expr {{
                        $argtype $argname;
                        // First, try to read the obj as a raw pointer.
                        if (sscanf(Jim_String($obj), "($argtype) 0x%p", &$argname) != 1) {
                            // No? Then try to coerce to a Tcl object.
#if $[dict exists $objtypes $basetype]
                                __ENSURE_OK($[set basetype]_setFromAnyProc(interp, $obj));
                                $argname = $obj->internalRep.ptrIntValue.ptr;
#else
                                FOLK_ERROR("Unable to convert $[set basetype]");
#endif
                        }
                    }}
                } else {
                    expr {{
                        $argtype $argname;
                        __ENSURE(sscanf(Jim_String($obj), "($argtype) 0x%p", &$argname) == 1);
                    }}
                }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                # note: arraylen can be ""
                if {$basetype eq "char"} { expr {{
                    char $argname[$arraylen]; memcpy($argname, Jim_String($obj), $arraylen);
                }} } else { expr {{
                    int $[set argname]_objc = Jim_ListLength(interp, $obj);
                    $basetype $argname[$[set argname]_objc];
                    {
                        for (int i = 0; i < $[set argname]_objc; i++) {
                            $[$self arg $basetype ${argname}_i "Jim_ListGetIndex(interp, $obj, i)"]
                            $argname[i] = $[set argname]_i;
                        }
                    }
                }} }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $argtype -> basetype arraylen arraylen2]} {
                expr {{
                    int $[set argname]_objc = Jim_ListLength(interp, $obj);
                    $basetype $argname[$[set argname]_objc][$arraylen2];
                    {
                        for (int j = 0; j < $[set argname]_objc; j++) {
                            $[$self arg $basetype\[\] ${argname}_j "Jim_ListGetIndex(interp, $obj, j)"]
                            memcpy(${argname}[j], ${argname}_j, sizeof(${argname}_j));
                        }
                    }
                }}
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
        int { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        int32_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        double { expr {{ $robj = Jim_NewDoubleObj(interp, $rvalue); }}}
        float { expr {{ $robj = Jim_NewDoubleObj(interp, $rvalue); }}}
        char { expr {{ $robj = Jim_NewStringObj(&$rvalue, 1); }}}
        bool { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        uint8_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        uint16_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        uint32_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        uint64_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        size_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        intptr_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
        char* { expr {{ $robj = Jim_NewStringObj(interp, $rvalue, -1); }} }
        Jim_Obj* { expr {{ $robj = $rvalue; }}}
        default {
            if {[string index $rtype end] == "*"} {
                expr {{ $robj = Jim_ObjPrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue); }}
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                if {$basetype eq "char"} { expr {{
                    $robj = Jim_ObjPrintf($rvalue);
                }} } else { expr {{
                    {
                        Jim_Obj* objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $[$self ret $basetype objv\[i\] $rvalue\[i\]]
                        }
                        $robj = Jim_NewListObj(interp, objv, $arraylen);
                    }
                }} }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $rtype -> basetype arraylen arraylen2]} { expr {{
                    {
                        Jim_Obj* objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $basetype* rrow = $rvalue[i];
                            Jim_Obj** objrow = &objv[i];
                            $[$self ret ${basetype}\[${arraylen2}\] *objrow rrow]
                        }
                        $robj = Jim_NewListObj(interp, objv, $arraylen);
                    }
            }} } else {
                error "Unrecognized rtype $rtype"
            }
        }
    }

    cflags {-I./vendor/jimtcl}
    endcflags {}

    cfile {}

    ___addrs_comment {
        # Used to store function pointers so you can import them
        # across modules.
    }
    addrs {}
}

# Registers a new argtype.
C method argtype {t h} {
    dict set argtypes $t [csubst {expr {{$h}}}]
}
# Looks up the argtype and returns C code to convert it.
C method arg {argtype argname obj} {
    csubst [eval [dict getdef $argtypes $argtype \
                      [dict get $argtypes default]]]
}

# Registers a new rtype.
C method rtype {t h} {
    dict set rtypes $t [csubst {expr {{$h}}}]
}
C method ret {rtype robj rvalue} {
    csubst [eval [dict getdef $rtypes $rtype \
                      [dict get $rtypes default]]]
}

C method include {h} {
    if {[llength $h] > 1} {
        lappend code $h :extend
        return
    }
    if {[string index $h 0] eq "<"} {
        lappend code "#include $h" :extend
    } else {
        lappend code "#include \"$h\"" :extend
    }
}

C method code {newcode} {
    lassign [info source $newcode] filename line
    if {$filename ne ""} { 
        set newcode [subst {
            #line $line "$filename"
            $newcode
        }]
    }
    lappend code $newcode :noextend
    list
}

C method define {newvars} {
    lappend code $newvars :noextend

    regsub -all -line {/\*.*?\*/} $newvars "" newvars
    regsub -all -line {//.*$} $newvars "" newvars
    regsub -all {=[^;]*;} $newvars "" newvars
    regsub -all {__thread \w+} $newvars {{\0}} newvars
    set newvars [string map {";" ""} $newvars]

    foreach {vartype varname} $newvars {
        if {[dict exists $vars $varname]} {
            error "var already exists: $varname"
        }
        dict set vars $varname $vartype
    }
}

C method enum {type values} {
    lappend code [subst {
        typedef enum $type $type;
        enum $type {$values};
    }] :extend

    regsub -all {,} $values "" values
    argtype $type [dict get $argtypes int]
    rtype $type [dict get $rtypes int]
}

C method typedef {t newt} {
    lappend code "typedef $t $newt;" :extend
    set argtype $t; set rtype $t

    try {
        $self argtype $newt [eval [dict getdef $argtypes $argtype \
                                       [dict get $argtypes default]]]
    } on error e {
        puts stderr "C typedef: $e"
    }
    try {
        $self rtype $newt [eval [dict getdef $rtypes $rtype \
                                     [dict get $rtypes default]]]
    } on error e {
        puts stderr "C typedef: $e"
    }
}

C method struct {type fields} {
    lappend code [subst {
        typedef struct $type $type;
        struct $type {$fields};
    }] :extend

    regsub -all -line {/\*.*?\*/} $fields "" fields
    regsub -all -line {//.*$} $fields "" fields
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

    $self include <string.h>
    # ptrAndLongRep.value = 1 means the data is owned by
    # the Jim_ObjType and should be freed by this
    # code. value = 0 means the data is owned externally
    # (by someone else like the statement store).
    dict set objtypes $type [csubst {
        $[join [lmap fieldname $fieldnames { subst {
            __thread Jim_Obj* k__${type}__${fieldname} = NULL;
        } }] "\n"]
        Jim_ObjType* $[set type]_ObjType;

        void $[set type]_freeIntRepProc(Jim_Interp* interp, Jim_Obj *objPtr) {
            if (objPtr->internalRep.ptrIntValue.int1 == 1) {
                free((char*)objPtr->internalRep.ptrIntValue.ptr);
            }
        }
        void $[set type]_dupIntRepProc(Jim_Interp* interp, Jim_Obj *srcPtr, Jim_Obj *dupPtr) {
            dupPtr->internalRep.ptrIntValue.ptr = malloc(sizeof($type));
            dupPtr->internalRep.ptrIntValue.int1 = 1;
            memcpy(dupPtr->internalRep.ptrIntValue.ptr, srcPtr->internalRep.ptrIntValue.ptr, sizeof($type));
        }
        void $[set type]_updateStringProc(Jim_Obj *objPtr) {
            $[set type] *robj = ($[set type] *) objPtr->internalRep.ptrIntValue.ptr;

            const char *format = "$[join [lmap fieldname $fieldnames {
                subst {$fieldname {%s}}
                }] { }]";
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Jim_Obj* robj_$fieldname;
                    $[$self ret $fieldtype robj_$fieldname robj->$fieldname]
                }
            }] "\n"]
            objPtr->length = snprintf(NULL, 0, format, $[join [lmap fieldname $fieldnames {expr {"Jim_String(robj_$fieldname)"}}] ", "]);
            objPtr->bytes = (char *) malloc(objPtr->length + 1);
            snprintf(objPtr->bytes, objPtr->length + 1, format, $[join [lmap fieldname $fieldnames {expr {"Jim_String(robj_$fieldname)"}}] ", "]);
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Jim_FreeNewObj(interp, robj_$fieldname);
                }
            }] "\n"]
        }
        int $[set type]_setFromAnyProc(Jim_Interp *interp, Jim_Obj *objPtr) {
            if (objPtr->typePtr == $[set type]_ObjType) { return JIM_OK; }

            $[set type] *robj = ($[set type] *)malloc(sizeof($[set type]));
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Jim_Obj* obj_$fieldname;
                    if (k__$[set type]__$fieldname == NULL) {
                        k__${type}__${fieldname} = Jim_NewStringObj(interp, "$fieldname", -1);
                        Jim_IncrRefCount(k__${type}__${fieldname});
                    }
                    __ENSURE_OK(Jim_DictKey(interp, objPtr, k__$[set type]__$fieldname, &obj_$fieldname, JIM_ERRMSG));

                    $[$self arg $fieldtype robj_$fieldname obj_${fieldname}]
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

    $self argtype $type [csubst {
        __ENSURE_OK($[set type]_setFromAnyProc(interp, \$obj));
        \$argtype \$argname;
        \$argname = *(($type *)\$obj->internalRep.ptrIntValue.ptr);
    }]

    $self rtype $type {
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
            if {$fieldtype ne "Jim_Obj*" &&
                [regexp {(^[^\[]+)(?:\[(\d*)\]|\*)(?:\[(\d+)\])?$} $fieldtype -> basefieldtype arraylen arraylen2]} {
                if {$basefieldtype eq "char"} {
                    $self proc ${type}_$fieldname {Jim_Interp* interp Jim_Obj* obj} char* {
                        __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                        return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                    }
                } else {
                    if {$arraylen2 eq ""} {
                        $self proc ${type}_${fieldname}_ptr {Jim_Interp* interp Jim_Obj* obj} $basefieldtype* {
                            __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                            return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                        }
                        set elementtype $basefieldtype
                    } else {
                        set elementtype $basefieldtype\[$arraylen2\]
                    }
                    # If fieldtype is a pointer or an array,
                    # then make a getter that takes an index.
                    $self proc ${type}_$fieldname {Jim_Interp* interp Jim_Obj* obj int idx} $elementtype {
                        __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                        return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname[idx];
                    }
                }
            } else {
                $self proc ${type}_$fieldname {Jim_Interp* interp Jim_Obj* obj} $fieldtype {
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

C method proc {name arguments rtype body} {
    set cname [string map {":" "_"} $name]
    lassign [info source $body] filename line
    set body [uplevel 2 [list csubst $body]]

    set arglist [list]
    set argnames [list]
    set loadargs [list]
    foreach {argtype argname} $arguments {
        lassign [typestyle $argtype $argname] argtype argname
        lappend arglist [join [cstyle $argtype $argname] " "]
        lappend argnames $argname

        if {$argtype == "Jim_Interp*" && $argname == "interp"} { continue }

        set obj [subst {objv\[1 + [llength $loadargs]\]}]
        lappend loadargs [$self arg {*}[typestyle $argtype $argname] $obj]
    }
    regsub {\[\d*\]} $rtype * decayedRtype
    if {$rtype == "void"} {
        set saverv [subst {
            $cname ([join $argnames ", "]);
            return JIM_OK;
        }]
    } else {
        set saverv [subst {
            $decayedRtype rvalue = $cname ([join $argnames ", "]);
            Jim_Obj* robj;
            [$self ret $rtype robj rvalue]
            Jim_SetResult(interp, robj);
            return JIM_OK;
        }]
    }

    if {[dict exists $procs $name]} { error "C proc: Name collision: $name" }
    dict set procs $name rtype $rtype
    dict set procs $name arglist $arglist
    dict set procs $name code [subst {
        static $decayedRtype $cname ([join $arglist ", "]) {
            [if {$filename ne ""} {
                subst {#line $line "$filename"}
            } else {list}]
            $body
        }

        static int [set cname]_Cmd(Jim_Interp* interp, int objc, Jim_Obj* const objv\[\]) {
            if (objc != 1 + [llength $loadargs]) {
                Jim_SetResultFormatted(interp, "Wrong number of arguments to $name");
                return JIM_ERR;
            }
            int __r = setjmp(__onError);
            if (__r != 0) { return JIM_ERR; }

            [join $loadargs "\n"]
            $saverv
        }
    }]
}

C method cflags {args} { lappend cflags {*}$args }
C method endcflags {args} { lappend endcflags {*}$args }

C method compile {{cid {}}} {
    set cfile [file tempfile /tmp/cfileXXXXXX].c

    # A universally unique id that can be used as a global proc name
    # in every thread.
    if {$cid eq {}} {
        set cid [file rootname [file tail $cfile]]
    }

    set init [subst {
        #include <string.h>
        static const char* _Atomic __cInfo = NULL;
        static int __setCInfo_Cmd(Jim_Interp* interp, int objc, Jim_Obj* const objv\[\]) {
            if (__cInfo != NULL || objc != 2) { return JIM_ERR; }
            const char* cInfo = Jim_String(objv\[1\]);
            if (cInfo == NULL) { return JIM_ERR; }
            __cInfo = strdup(cInfo);
            return JIM_OK;
        }
        static __thread Jim_Obj* __cInfoObj = NULL;
        static int __getCInfo_Cmd(Jim_Interp* interp, int objc, Jim_Obj* const objv\[\]) {
            if (__cInfo == NULL || objc != 1) { return JIM_ERR; }
            if (__cInfoObj == NULL) {
                __cInfoObj = Jim_NewStringObj(interp, __cInfo, -1);
                Jim_IncrRefCount(__cInfoObj);
            }
            Jim_SetResult(interp, __cInfoObj);
            return JIM_OK;
        }

        int Jim_${cid}Init(Jim_Interp* intp) {
            interp = intp;

            Jim_CreateCommand(interp, "<C:$cid> __setCInfo", __setCInfo_Cmd, NULL, NULL);
            Jim_CreateCommand(interp, "<C:$cid> __getCInfo", __getCInfo_Cmd, NULL, NULL);

            [join [lmap varname [dict keys $vars] {
                csubst {{
                    char script[1000];
                    snprintf(script, 1000, "dict set {::<C:$cid> __addrs} $varname %p", &$varname);
                    Jim_Eval(interp, script);
                }}
            }] "\n"]

            [join [lmap name [dict keys $procs] {
                set cname [string map {":" "_"} $name]
                set tclname $name
                # puts "Creating C command: $tclname"
                csubst {{
                    char script[1000];
                    snprintf(script, 1000, "dict set {::<C:$cid> __addrs} $cname %p", $cname);
                    Jim_Eval(interp, script);

                    Jim_CreateCommand(interp, "<C:$cid> $tclname", $[set cname]_Cmd, NULL, NULL);
                }}
            }] "\n"]

            [join [lmap type [dict keys $objtypes] { subst {
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
                              $prelude \
                              $unexternC \
                              \
                              {*}[lmap {snippet extend} $code {set snippet}] \
                              \
                              $externC \
                              {*}[dict values $objtypes] \
                              {*}[lmap p [dict values $procs] {dict get $p code}] \
                              $init \
                              $unexternC \
                             ] "\n"]

    # puts "=====================\n$sourcecode\n====================="

    set cfd [open $cfile w]; puts $cfd $sourcecode; close $cfd
    set ignoreUnresolved {}; if {$::tcl_platform(os) eq "linux"} {
        set ignoreUnresolved -Wl,--unresolved-symbols=ignore-all
    } elseif {$::tcl_platform(os) eq "darwin"} {
        set ignoreUnresolved -Wl,-undefined,dynamic_lookup
    }
    if {[__isTracyEnabled]} {
        lappend cflags -DTRACY_ENABLE=1
    }
    exec $compiler -Wall -g -fno-omit-frame-pointer -fPIC \
        {*}$cflags $cfile -c -o [file rootname $cfile].o
    # HACK: Why do we need this / only when running in lldb?
    while {![file exists [file rootname $cfile].o]} { sleep 0.0001 }

    exec $compiler -shared $ignoreUnresolved \
        -o /tmp/$cid.so [file rootname $cfile].o \
        {*}$endcflags
    # HACK: Why do we need this / only when running in lldb?
    while {![file exists /tmp/$cid.so]} { sleep 0.0001 }

    set cInfo [dict create]
    foreach varName [$self vars] {
        dict set cInfo $varName [$self get $varName]
    }
    
    # Load the compiled module immediately so we can set its C info.
    <C:$cid>
    <C:$cid> __setCInfo $cInfo

    return <C:$cid>
}

C method import {srclib srcname {_as {}} {destname {}}} {
    if {$destname eq ""} { set destname $srcname }

    set procinfo [dict get [$srclib __getCInfo] procs $srcname]
    set rtype [dict get $procinfo rtype]
    set arglist [dict get $procinfo arglist]

    set addr [dict get [set "::$srclib __addrs"] $srcname]
    $self code "$rtype (*$destname) ([join $arglist {, }]) = ($rtype (*) ([join $arglist {, }])) $addr;"
}

C method string_toupper_first {s} {
    return [string toupper [string index $s 0]][string range $s 1 end]
}
C method extend {srclib} {
    set srcinfo [$srclib __getCInfo]
    set srcaddrs [set "::$srclib __addrs"]

    foreach {snippet extend} [dict get $srcinfo code] {
        if {$extend eq ":extend"} {
            lappend code $snippet :extend
        }
    }

    set argtypes [dict merge [dict get $srcinfo argtypes] $argtypes]
    set rtypes [dict merge [dict get $srcinfo rtypes] $rtypes]
    dict for {objtype _} [dict get $srcinfo objtypes] {
        $self code "int (*${objtype}_setFromAnyProc)(Jim_Interp *interp, Jim_Obj *objPtr) = \
(int (*)(Jim_Interp *interp, Jim_Obj *objPtr)) \
[dict get $srcaddrs ${objtype}_setFromAnyProc];"
       $self code "Jim_ObjType* ${objtype}_ObjType = (Jim_ObjType*) [dict get $srcaddrs ${objtype}_ObjType];"
    }

    foreach procName [dict keys [dict get $srcinfo procs]] {
        $self import $srclib $procName
    }

    dict for {varname vartype} [dict get $srcinfo vars] {
        set addr [dict get $srcaddrs $varname]
        if {[llength $vartype] == 2 && [lindex $vartype 0] eq "__thread"} {
            $self code "$vartype* ${varname}__ptr = ([lindex $vartype 1]*) $addr;"
            set vartype [lindex $vartype 1]
        } else {
            $self code "$vartype* ${varname}__ptr = ($vartype*) $addr;"
        }
        $self code [subst {
            $vartype get[$self string_toupper_first $varname]() {
                return *(${varname}__ptr);
            }
        }]
    }
}

proc ::C++ {} {
    set cpp [C]
    $cpp eval [list set compiler c++]
    $cpp cflags -Wno-write-strings
    return $cpp
}
