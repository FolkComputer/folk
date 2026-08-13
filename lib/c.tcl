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
    if {[regexp {([^\[]+)(\[[^\]]*\](\[[^\]]*\])?)$} $type -> basetype arraysuffix]} {
        # Normalize any named dimension (identifier) to [] for the C declaration.
        regsub {\[[a-zA-Z_]\w*\]} $arraysuffix {[]} arraysuffix
        list $basetype $name$arraysuffix
    } else {
        list $type $name
    }
}
# Converts something like {int x[10]} to {int[10] x}. That way the array type
# is moved out of the name and into the type.
fn typestyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $name -> basename arraysuffix]} {
        list $type$arraysuffix $basename
    } else {
        list $type $name
    }
}

# Emits one C statement per Zicl_Value-bearing field in $fields, substituting
# %V for the field's expression on a struct reached through $structExpr (e.g.
# "struct_ptr" for a `$type*`). Array fields loop over each element. Only
# matches a field that is directly `Zicl_Value` or `Zicl_Value[N]` -- like the
# getter-generation loop in C::struct, this does not look inside a nested
# struct field's own fields.
fn foreachZiclValueField {fields structExpr opTemplate} {
    join [lmap {fieldtype fieldname} $fields {
        if {$fieldtype eq "Zicl_Value"} {
            string map [list %V "$structExpr->$fieldname"] $opTemplate
        } elseif {[regexp {^Zicl_Value\[(\d*)\]$} $fieldtype -> arraylen]} {
            set stmt [string map [list %V "$structExpr->$fieldname\[i\]"] $opTemplate]
            subst {for (int i = 0; i < $arraylen; i++) { $stmt }}
        } else {
            continue
        }
    }] "\n"
}

set C {
    compiler cc
    prelude {
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

        extern __thread Zicl_Interp* interp;
        extern __thread jmp_buf __onError;
        extern __thread bool __onErrorIsSet;

        #define __ENSURE(EXPR) if (!(EXPR)) { Zicl_SetErrorString(interp, "failed to convert argument from Tcl to C in: " #EXPR, -1); longjmp(__onError, 0); }
        #define __ENSURE_OK(EXPR) if ((EXPR) != ZICL_OK) { longjmp(__onError, 0); }

        #define FOLK_ERROR(...) do { \
            char __msg[1024]; snprintf(__msg, 1024, ##__VA_ARGS__); \
            Zicl_SetErrorString(interp, __msg, -1); \
            longjmp(__onError, 0); \
          } while (0)
        #define FOLK_ABORT() longjmp(__onError, 0)
        #define FOLK_ENSURE(EXPR) if (!(EXPR)) { Zicl_SetErrorString(interp, "assertion failed: " #EXPR, -1); longjmp(__onError, 0); }
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
        Zicl_Shimmerable* { identity { Zicl_Shimmerable* $argname = $shim; }}
        default {
            if {[string index $argtype end] == "*"} {
                set basetype [string range $argtype 0 end-1]
                error "Need to port this to the capability framework"
            } elseif {[regexp {(^[^\[]+)\[([^\]]*)\]$} $argtype -> basetype arraylen]} {
                # note: arraylen can be "" or a named identifier
                if {$basetype eq "char"} { identity {
                    int $[set argname]_len; const char *$[set argname]_bytes = ziclShimString($shim, &len);
                    if ($[set argname]_len > $arraylen) $[set argname]_len = $arraylen;
                    char $argname[$arraylen]; memcpy($argname, $[set argname]_bytes, $[set argname]_len);
                } } else {
                    if {[regexp {^[a-zA-Z_]} $arraylen]} {
                        set countvar $arraylen
                    } else {
                        set countvar ${argname}_objc
                    }
                    identity {
                    const Zicl_List *$[set argname]_list = __ENSURE(Zicl_ListShimmer(interp, $shim, &$[set argname]_list));
                    int $countvar = Zicl_ListLength($[set argname]_list);
                    const Zicl_Value *$[set argname]_objv = Zicl_ListItems($[set argname]_list);
                    $basetype $argname[$countvar];
                    {
                        for (int i = 0; i < $countvar; i++) {
                            Zicl_Shimmerable $[set argname]_shim = Zicl_NewShimmerable($[set argname]_objv[i]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim); }
                            $[self::arg $basetype ${argname}_i "&$[set argname]_shim"]
                            $argname[i] = $[set argname]_i;
                        }
                    }
                } }
            } elseif {[regexp {(^[^\[]+)\[([^\]]*)\]\[(\d*)\]$} $argtype -> basetype arraylen arraylen2]} {
                # If arraylen is a named identifier, expose it as that C variable name.
                if {[regexp {^[a-zA-Z_]} $arraylen]} {
                    set countvar $arraylen
                } else {
                    set countvar ${argname}_objc
                }
                identity {
                    const Zicl_List *$[set argname]_list = __ENSURE(Zicl_ListShimmer(interp, $shim, &$[set argname]_list_2));
                    int $countvar = Zicl_ListLength($[set argname]_list);
                    const Zicl_Value *$[set argname]_objv = Zicl_ListItems($[set argname]_list);
                    $basetype $argname[$countvar][$arraylen2];
                    {
                        for (int j = 0; j < $countvar; j++) {
                            Zicl_Shimmerable $[set argname]_shim = Zicl_NewShimmerable($[set argname]_objv[j]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim); }
                            $[self::arg $basetype\[\] ${argname}_j "&$[set argname]_shim"]
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
        int { identity { $robj = Zicl_NewLong($rvalue); }}
        int32_t { identity { $robj = Zicl_NewLong($rvalue); }}
        double { identity { $robj = Zicl_NewLong($rvalue); }}
        float { identity { $robj = Zicl_NewLong($rvalue); }}
        char { identity { $robj = ziclNewString(&$rvalue, 1); }}
        bool { identity { $robj = Zicl_NewLong($rvalue); }}
        uint8_t { identity { $robj = Zicl_NewLong($rvalue); }}
        uint16_t { identity { $robj = Zicl_NewLong($rvalue); }}
        uint32_t { identity { $robj = Zicl_NewLong($rvalue); }}
        uint64_t { identity { $robj = Zicl_NewLong((uint64_t)($rvalue)); }}
        size_t { identity { $robj = Zicl_NewLong($rvalue); }}
        intptr_t { identity { $robj = Zicl_NewLong($rvalue); }}
        char* { identity { $robj = ziclNewString($rvalue, -1); } }
        Zicl_Value { identity { $robj = $rvalue; }}
        default {
            if {[string index $rtype end] eq "*"} {
                identity { folkZiclAssert(Zicl_NewStringFormatted(&$robj, "($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue));  }
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

method C::addcode {self newcode {extendArg {:noextend}}} {
    lassign [info source $newcode] filename line
    if {$filename ne ""} { 
        set newcode [subst {
            $newcode
        }]
    }
    lappend self::code $newcode {*}$extendArg
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

    # Remove any C comments.
    regsub -all -line {/\*.*?\*/} $fields "" fields
    regsub -all -line {//.*$} $fields "" fields
    if {[regsub -all {\s_Atomic\s} $fields " " fields] > 0} {
        puts stderr "C struct $type: Warning: Will ignore _Atomic for getters and setters"
    }
    # By removing comments, and now semicolons, `fields` becomes a list
    # of alternating field type and field name.
    set fields [string map {";" ""} $fields]

    set fieldnames [list]
    for {set i 0} {$i < [llength $fields]} {incr i 2} {
        set fieldtype [lindex $fields $i]
        set fieldname [lindex $fields $i+1]
        # Canonicalize type.
        lassign [typestyle $fieldtype $fieldname] fieldtype fieldname
        lappend fieldnames $fieldname
        lset fields $i $fieldtype
        lset fields $i+1 $fieldname
    }

    self::include <string.h>
    dict set objtypes $type [csubst {
        Zicl_ObjectVTable* $[set type]_ObjectVTable;

        void $[set type]_freeIntRepProc(Zicl_Object* objPtr) {
            $type* struct_ptr = NULL;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                struct_ptr = *(($type**)&objPtr->body_backing);
            } else {
                struct_ptr = ($type*)&objPtr->body_backing;
            }

            $[foreachZiclValueField $fields "struct_ptr" {Zicl_Release(%V);}]

            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                // The body is a pointer to the struct we allocated, since it was
                // too big to fit into the backing.
                free(struct_ptr);
            }
        }
        Zicl_Object* $[set type]_dupIntRepProc(const Zicl_Object* srcPtr) {
            $type* allocated_struct = NULL;
            size_t struct_size = sizeof($type);
            // If the struct size is larger than what Zicl allows to be in the object
            // body, we allocate the struct separately.
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                allocated_struct = malloc(sizeof($type));
                struct_size = sizeof($type*);
            }

            uint8_t* body = NULL;
            Zicl_Object* new_object = Zicl_NewObject($[set type]_ObjectVTable, struct_size, &body);

            $type* dest_struct;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                $type* src_struct = *(($type**)&srcPtr->body_backing);
                memcpy(allocated_struct, src_struct, sizeof($type));
                *(($type**)body) = allocated_struct;
                dest_struct = allocated_struct;
            } else {
                *(($type*)body) = *(($type*)&srcPtr->body_backing);
                dest_struct = ($type*)body;
            }

            $[foreachZiclValueField $fields "dest_struct" {%V = Zicl_Borrow(%V);}]

            return new_object;
        }
        void $[set type]_makeCrossthreadProc(Zicl_Object* objPtr) {
            $type* struct_ptr = NULL;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                struct_ptr = *(($type**)&objPtr->body_backing);
            } else {
                struct_ptr = ($type*)&objPtr->body_backing;
            }

            $[foreachZiclValueField $fields "struct_ptr" {Zicl_MakeCrossthread(%V);}]
        }
        int $[set type]_updateStringProc(Zicl_Object* objPtr) {
            $type* struct_ptr = NULL;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                struct_ptr = *(($type**)&objPtr->body_backing);
            } else {
                struct_ptr = ($type*)&objPtr->body_backing;
            }

            const char *format = "$[join [lmap fieldname $fieldnames {
                subst {$fieldname {%s}}
                }] { }]";
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_Value struct_$fieldname;
                    $[self::ret $fieldtype struct_$fieldname struct_ptr->$fieldname]
                }
            }] "\n"]
            // Calculate the length first, so we can allocate the right number of bytes.
            size_t bytes_len = snprintf(NULL, 0, format, $[join [lmap fieldname $fieldnames {subst {ziclString(struct_$fieldname)}}] ", "]);
            char* bytes = malloc(bytes_len + 1);
            defer { free(bytes); }
            snprintf(bytes, bytes_len + 1, format, $[join [lmap fieldname $fieldnames {subst {ziclString(struct_$fieldname)}}] ", "]);
            folkZiclAssert(Zicl_SetObjectString(objPtr, bytes, bytes_len));
            $[join [lmap {fieldtype fieldname} $fields {
                subst {Zicl_Release(struct_$fieldname);}
            }] "\n"]
            return ZICL_OK;
        }
        int $[set type]_shimmerFrom(Zicl_Interp *interp, Zicl_Shimmerable* shim, $type** out) {
            void* body = Zicl_AsObject(Zicl_Current(shim), $[set type]_ObjectVTable);
            if (body) {
                *out = (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) ? *($type**)body : ($type*)body;
                return ZICL_OK;
            }

            $type robj;
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_OptionalValue obj_$fieldname;
                    __ENSURE_OK(Zicl_ShimDictGet(interp, shim, Zicl_InternStr("$fieldname"), &obj_$fieldname));
                    __ENSURE(Zicl_IsSome(obj_$fieldname));
                    Zicl_Shimmerable shim_$fieldname = Zicl_NewShimmerable(Zicl_Unwrap(obj_$fieldname));
                    defer { Zicl_ShimDiscardChanges(&shim_$fieldname); }
                    $[self::arg $fieldtype robj_$fieldname "&shim_$fieldname"]
                    robj.$fieldname = robj_$fieldname;
                }
            }] "\n"]

            void* new_body = Zicl_PrepareToShimmer(shim, $[set type]_ObjectVTable);
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                $type* allocated_struct = malloc(sizeof($type));
                memcpy(allocated_struct, &robj, sizeof($type));
                *(($type**)new_body) = allocated_struct;
                *out = allocated_struct;
            } else {
                memcpy(new_body, &robj, sizeof($type));
                *out = ($type*)new_body;
            }

            return ZICL_OK;
        }

        /* Returns a list of addresses for all the vtable functions. */
        Zicl_Dict* $[set type]_init(Zicl_Interp* interp, const char* cid) {
            $[set type]_ObjectVTable = malloc(sizeof(Zicl_ObjectVTable));
            *$[set type]_ObjectVTable = (Zicl_ObjectVTable) {
                .is_c_vtable = true,
                .name = "$type",
                .duplicate = $[set type]_dupIntRepProc,
                .free_internal_rep = $[set type]_freeIntRepProc,
                .update_string = $[set type]_updateStringProc,
                .make_crossthread = $[set type]_makeCrossthreadProc,
                .enumerate_struct = NULL
                // .shimmerFrom = $[set type]_shimmerFrom
            };

            Zicl_Dict* addresses = Zicl_NewDict(NULL, 0);

            Zicl_Value shimmer_from_ptr; folkZiclAssert(Zicl_NewStringFormatted(&shimmer_from_ptr, "%p", &$[set type]_shimmerFrom));
            defer { Zicl_Release(shimmer_from_ptr); }
            Zicl_Value object_vtable_ptr; folkZiclAssert(Zicl_NewStringFormatted(&object_vtable_ptr, "%p", $[set type]_ObjectVTable));
            defer { Zicl_Release(object_vtable_ptr); }

            ziclDictPut(addresses, Zicl_InternStr("$[set type]_shimmerFrom"), shimmer_from_ptr);
            ziclDictPut(addresses, Zicl_InternStr("$[set type]_ObjectVTable"), object_vtable_ptr);

            return addresses;
        }
    }]

    self::argtype $type [csubst {
        $type \$argname;
        {
            $type* struct_ptr;
            __ENSURE_OK($[set type]_shimmerFrom(interp, \$shim, &struct_ptr));
            \$argname = *struct_ptr;
        }
    }]

    self::rtype $type [csubst {
        {
            size_t struct_size = sizeof($type);
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) { struct_size = sizeof($type*); }

            void* body = NULL;
            Zicl_Object* obj = Zicl_NewObject($[set type]_ObjectVTable, struct_size, &body);

            $type* dest_struct;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                dest_struct = malloc(sizeof($type));
                *(($type**)body) = dest_struct;
            } else {
                dest_struct = ($type*)body;
            }
            *dest_struct = \$rvalue;

            $[foreachZiclValueField $fields {dest_struct} {%V = Zicl_Borrow(%V);}]

            \$robj = Zicl_BoxObject(obj);
        }
    }]

    # Generate Tcl getter functions for each field:
    foreach {fieldtype fieldname} $fields {
        try {
            if {$fieldtype ne "Zicl_Value" &&
                [regexp {(^[^\[]+)(?:\[(\d*)\]|\*)(?:\[(\d+)\])?$} $fieldtype -> basefieldtype arraylen arraylen2]} {
                if {$basefieldtype eq "char"} {
                    self::proc ${type}_$fieldname {Zicl_Interp* interp Zicl_Shimmerable* shim} char* {
                        $type* struct_ptr;
                        __ENSURE_OK($[set type]_shimmerFrom(interp, shim, &struct_ptr));
                        return struct_ptr->$fieldname;
                    }
                } else {
                    if {$arraylen2 eq ""} {
                        self::proc ${type}_${fieldname}_ptr {Zicl_Interp* interp Zicl_Shimmerable* shim} $basefieldtype* {
                            $type* struct_ptr;
                            __ENSURE_OK($[set type]_shimmerFrom(interp, shim, &struct_ptr));
                            return struct_ptr->$fieldname;
                        }
                        set elementtype $basefieldtype
                    } else {
                        set elementtype $basefieldtype\[$arraylen2\]
                    }
                    # If fieldtype is a pointer or an array,
                    # then make a getter that takes an index.
                    self::proc ${type}_$fieldname {Zicl_Interp* interp Zicl_Shimmerable* shim int idx} $elementtype {
                        $type* struct_ptr;
                        __ENSURE_OK($[set type]_shimmerFrom(interp, shim, &struct_ptr));
                        return struct_ptr->$fieldname[idx];
                    }
                }
            } elseif {$fieldtype eq "Zicl_Value"} {
                # The field is itself a Zicl_Value living inside the struct, so
                # borrow it before returning: it may point into a shimmered
                # duplicate whose lifetime we don't own (see argtypes.Zicl_Value),
                # and self::ret's Zicl_Value conversion is a bare alias that
                # expects an already-owned reference, same as elsewhere in this
                # codebase (e.g. folk.c's `Zicl_Borrow(bTerms[i])`).
                self::proc ${type}_$fieldname {Zicl_Interp* interp Zicl_Shimmerable* shim} $fieldtype {
                    $type* struct_ptr;
                    __ENSURE_OK($[set type]_shimmerFrom(interp, shim, &struct_ptr));
                    return Zicl_Borrow(struct_ptr->$fieldname);
                }
            } else {
                self::proc ${type}_$fieldname {Zicl_Interp* interp Zicl_Shimmerable* shim} $fieldtype {
                    $type* struct_ptr;
                    __ENSURE_OK($[set type]_shimmerFrom(interp, shim, &struct_ptr));
                    return struct_ptr->$fieldname;
                }
            }
        } on error e {
            puts stderr "Warning: Unable to generate getter for `$type $fieldname`: $e"
        }
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

        # If type has a named first dimension (e.g. int[n] or float[n][4]),
        # inject that dimension as an implicit int parameter before the array.
        if {[regexp {^[^\[]+\[([a-zA-Z_]\w*)\]} $argtype -> dimname]} {
            lappend arglist "int $dimname"
            lappend argnames $dimname
        }

        lappend arglist [join [cstyle $argtype $argname] " "]
        lappend argnames $argname

        if {$argtype eq "Zicl_Interp*" && $argname eq "interp"} { continue }

        set obj [subst {(&argv\[1 + [llength $loadargs]\])}]
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
            Zicl_Value robj;
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

        static int [set cname]_Cmd(Zicl_Interp* interp, int argc, Zicl_Shimmerable *argv) {
            if (argc != 1 + [llength $loadargs]) {
                Zicl_SetResultString(interp, "Wrong number of arguments to $name", -1);
                return ZICL_ERR;
            }
            bool didSetOnError = false;
            if (!__onErrorIsSet) {
                int __r = setjmp(__onError);
                __onErrorIsSet = true;
                didSetOnError = true;

                if (__r != 0) {
                    __onErrorIsSet = false;
                    return ZICL_ERR;
                }
            }

            [join $loadargs "\n"]
            $saverv

            if (didSetOnError) {
                __onErrorIsSet = false;
            }
            return ZICL_OK;
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

    set nProcs [llength [dict keys $self::procs]]
    if {$nProcs == 0} { set nProcs 1 }

    set init [subst {
        static void ${cid}_register(void* intp_raw) {
            interp = (Zicl_Interp*) intp_raw;

            [join [lmap srcid $self::extends {
                subst {${srcid}_register(interp);}
            }] "\n"]

            [join [lmap name [dict keys $self::procs] {
                set cname [string map {":" "_" "!" "_"} $name]
                subst {Zicl_CreateCommand(interp, "${cid}::${name}", ${cname}_Cmd, "", 0, -1);}
            }] "\n"]
        }

        Zicl_Dict* Zicl_${cid}Init(Zicl_Interp* intp) {
            Zicl_Value __pairs\[$nProcs * 2\];
            int __n = 0;

            [join [lmap name [dict keys $self::procs] {
                subst {
                    if (Zicl_RegisterLazyFn("${cid}::${name}", "${cid}", ${cid}_register) != ZICL_OK) {
                        Zicl_SetErrorString(intp, "failed to register ${cid}::${name}", -1);
                        return NULL;
                    }
                    __pairs\[__n++\] = ziclNewString("${name}", -1);
                    __pairs\[__n++\] = ziclNewString("${cid}::${name}", -1);
                }
            }] "\n"]

            return ziclNewDict(__pairs, __n);
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

    exec [list $self::compiler {*}$asan_flags -shared $ignoreUnresolved \
        -O2 -o /tmp/$cid.so [file rootname $cfile].o \
        {*}$self::endcflags]

    # HACK: Why do we need this / only when running in lldb?
    set n 0
    while {![file exists /tmp/$cid.so]} {
        sleep 0.01
        incr n
        if {$n > 200} { error "Failed on /tmp/$cid.so! Timed out" }
    }

    if {$noload} {
        # Return the name of the compiled file instead of loading it.
        return /tmp/$cid.so
    }

    return [load /tmp/$cid.so]
}

# STALE: relies on `__getCInfo`/`__addrs`, which `C::compile` no longer
# generates now that a library is a plain dict (see `load`). Nothing in the
# current tree calls `C::import`/`C::extend`; porting them means deciding how
# cross-compilation-unit direct-calling should work against the new dict
# shape, not a mechanical fix.
method C::import {self srclib srcname {_as {}} {destname {}}} {
    if {$destname eq ""} { set destname $srcname }

    set procinfo [dict get [$srclib __getCInfo] procs $srcname]
    set rtype [dict get $procinfo rtype]
    set arglist [dict get $procinfo arglist]

    set addr [dict get [set "::$srclib __addrs"] $srcname]
    regsub {\[\d*\]} $rtype * decayedRtype
    self::addcode "$decayedRtype (*$destname) ([join $arglist {, }]) = ($decayedRtype (*) ([join $arglist {, }])) $addr;"
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
    set addr [dict get $srcaddrs Zicl_${srcid}Init]
    self::addcode "int (*Zicl_${srcid}Init)(Zicl_Interp* intp) =
                     (int (*)(Zicl_Interp* intp)) $addr;"

    lappend extends $srcid
}

fn C++ {} {
    set cpp [C]
    $cpp eval [list set compiler c++]
    $cpp addcflags -Wno-write-strings
    return $cpp
}
