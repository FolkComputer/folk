# lib/c.tcl --
#
#     Implements the C 'FFI' that lets you embed arbitrary C/C++ code
#     into a Tcl program. Especially useful for calling existing C
#     APIs and libraries (i.e., almost anything involving hardware or
#     the OS -- graphics, webcams, multithreading).
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
                lappend result $next
            }
            {$} {
                set remaining [string range $s $i end]
                try {
                    # Try parsing as a variable substitution.
                    lassign [vm parse variable $remaining] varname advance
                    incr i [- $advance 1]

                    lappend result [uplevel [list set $varname]]
                } on error {} {
                    # Even if it's variable substitution, it might be
                    # command substitution.
                    try {
                        lassign [vm parse command $remaining] cmd advance
                        incr i [- $advance 1]

                        lappend result [uplevel $cmd]
                    } on error {} {
                        # Wasn't any of those, so we'll just throw the character on.
                        lappend result $c
                    }
                }
            }
            default {lappend result $c}
        }
    }
    join $result ""
}
# Opposite of [typestyle]. Moves an array suffix from the type to the name,
# going from "int[10] x" to "int x[10]". We use the array suffix in the type
# name for canonicity, but move it to the end when generating C arguments,
# using this function.
fn cstyle {type name} {
    if {[regexp {([^\[]+)(\[[^\]]*\](\[[^\]]*\])?)$} $type -> basetype arraysuffix]} {
        # Normalize any named dimension (identifier) to [] for the C declaration.
        regsub {\[[a-zA-Z_]\w*\]} $arraysuffix {[]} arraysuffix
    } else {
        set basetype $type
        set arraysuffix ""
    }
    list $basetype $name$arraysuffix
}
# Converts something like "int x[10]" to "int[10] x". That way the array type
# is moved out of the name and into the type.
fn typestyle {type name} {
    if {[regexp {([^\[]+)(\[\d*\](\[\d*\])?)$} $name -> basename arraysuffix]} {
        list $type$arraysuffix $basename
    } else {
        list $type $name
    }
}

# Emits one C statement per Zicl_Val-bearing field in $fields, substituting
# %V for the field's expression on a struct reached through $structExpr (e.g.
# "struct_ptr" for a `$type*`). Array fields loop over each element. Only
# matches a field that is directly `Zicl_Val` or `Zicl_Val[N]` -- like the
# getter-generation loop in C::struct, this does not look inside a nested
# struct field's own fields.
fn foreachZiclValueField {fields structExpr opTemplate} {
    join [lmap {fieldtype fieldname} $fields {
        if {$fieldtype eq "Zicl_Val"} {
            string map [list %V "$structExpr->$fieldname"] $opTemplate
        } elseif {[regexp {^Zicl_Val\[(\d*)\]$} $fieldtype -> arraylen]} {
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
        #include <inttypes.h>
        #include <stdint.h>
        #include <stdbool.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <stddef.h>
        #include <string.h>
        #include <setjmp.h>
        #include <libzicl.h>
        #include "zicl-helpers.h"

        #if __has_include ("tracy/TracyC.h")
        #include "tracy/TracyC.h"
        #endif

        extern __thread Zicl_Interp* interp;
        extern __thread jmp_buf __onError;
        extern __thread bool __onErrorIsSet;

        typedef struct __CapCleanup {
            Zicl_CapHead* heads[16];
            int count;
        } __CapCleanup;
        static __thread __CapCleanup __capCleanup;

        static inline void __capCleanupDefer(Zicl_CapHead* head) {
            if (__capCleanup.count < 16) {
                __capCleanup.heads[__capCleanup.count++] = head;
            }
        }

        static inline void __capCleanupRunTo(int base) {
            while (__capCleanup.count > base) {
                Zicl_CapDropInFlight(__capCleanup.heads[--__capCleanup.count]);
            }
        }

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
    extendedObjtypes {}

    extends {}

    ___argtypes_comment {
        # Tcl->C conversion logic, when a value is passed from Tcl
        # to a C function as an argument.
    }
    argtypes {
        int {identity { long _$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_$argname)); int $argname = (int)_$argname; }}
        double {identity { double $argname; __ENSURE_OK(Zicl_GetDouble(interp, $shim, &$argname)); }}
        float {identity { double _$argname; __ENSURE_OK(Zicl_GetDouble(interp, $shim, &_$argname)); float $argname = (float)_$argname; }}
        bool {identity { int _$argname; __ENSURE_OK(Zicl_GetBoolean(interp, $shim, &_$argname)); bool $argname = !!_$argname; }}
        int32_t {identity { long _$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_$argname)); int32_t $argname = (int)_$argname; }}
        char {identity {
            char $argname;
            {
                int _len_$argname;
                char* _tmp_$argname = ziclShimGetString($shim, &_len_$argname);
                __ENSURE(_len_$argname >= 1);
                $argname = _tmp_$argname[0];
            }
        }}
        size_t {identity { size_t $argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, (long *)&$argname)); }}
        intptr_t {identity { intptr_t $argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, (long *)&$argname)); }}
        uint16_t {identity { uint16_t $argname; { long _wide_$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_wide_$argname)); $argname = (uint16_t)_wide_$argname; } }}
        uint32_t {identity { uint32_t $argname; { long _wide_$argname; __ENSURE_OK(Zicl_GetLong(interp, $shim, &_wide_$argname)); $argname = (uint32_t)_wide_$argname; } }}
        uint64_t {identity { uint64_t $argname; __ENSURE(sscanf(ziclShimString($shim), "%" PRIu64, &$argname) == 1); }}
        char* {identity { char* $argname = (char*) ziclShimString($shim); } }
        Zicl_Val {identity { Zicl_Val $argname = Zicl_Current($shim); }}
        Zicl_Shim* {identity { Zicl_Shim* $argname = $shim; }}
        default {
            if {[string index $argtype end] eq "*"} {
                identity {
                    $argtype $argname;
                    __ENSURE(sscanf(ziclShimString($shim), "($argtype) 0x%p", (void**) &$argname) == 1 ||
                             sscanf(ziclShimString($shim), "0x%p", (void**) &$argname) == 1);
                }
            } elseif {[regexp {(^[^\[]+)\[([^\]]*)\]$} $argtype -> basetype arraylen]} {
                # note: arraylen can be "" or a named identifier
                if {$basetype eq "char"} {identity {
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
                    const Zicl_List *$[set argname]_list;
                    __ENSURE_OK(Zicl_ShimmerToList(interp, $shim, &$[set argname]_list));
                    int $countvar = Zicl_ListLength($[set argname]_list);
                    const Zicl_Val *$[set argname]_objv = Zicl_ListItems($[set argname]_list);
                    $basetype $argname[$countvar];
                    {
                        for (int i = 0; i < $countvar; i++) {
                            Zicl_Shim $[set argname]_shim = Zicl_NewShim($[set argname]_objv[i]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim); }
                            $[self::arg $basetype ${argname}_i "&[set argname]_shim"]
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
                    const Zicl_List *$[set argname]_list;
                    __ENSURE_OK(Zicl_ShimmerToList(interp, $shim, &$[set argname]_list));
                    int $countvar = Zicl_ListLength($[set argname]_list);
                    const Zicl_Val *$[set argname]_objv = Zicl_ListItems($[set argname]_list);
                    $basetype $argname[$countvar][$arraylen2];
                    {
                        for (int j = 0; j < $countvar; j++) {
                            Zicl_Shim $[set argname]_shim = Zicl_NewShim($[set argname]_objv[j]);
                            defer { Zicl_ShimDiscardChanges(&$[set argname]_shim); }
                            $[self::arg $basetype\[\] ${argname}_j "&[set argname]_shim"]
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
        int {identity { $robj = Zicl_NewLong($rvalue); }}
        int32_t {identity { $robj = Zicl_NewLong($rvalue); }}
        double {identity { $robj = Zicl_NewLong($rvalue); }}
        float {identity { $robj = Zicl_NewLong($rvalue); }}
        char {identity { $robj = ziclNewString(&$rvalue, 1); }}
        bool {identity { $robj = Zicl_NewBool($rvalue); }}
        uint8_t {identity { $robj = Zicl_NewLong($rvalue); }}
        uint16_t {identity { $robj = Zicl_NewLong($rvalue); }}
        uint32_t {identity { $robj = Zicl_NewLong($rvalue); }}
        uint64_t {identity { $robj = Zicl_NewLong((uint64_t)($rvalue)); }}
        size_t {identity { $robj = Zicl_NewLong($rvalue); }}
        intptr_t {identity { $robj = Zicl_NewLong($rvalue); }}
        char* {identity { $robj = ziclNewString($rvalue, -1); } }
        Zicl_Val {identity { $robj = $rvalue; }}
        default {
            if {[string index $rtype end] eq "*"} {
                identity { folkZiclAssert(Zicl_NewStringFormatted(&$robj, "($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue)); }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                if {$basetype eq "char"} {identity {
                    $robj = ziclValuePrintf($rvalue);
                } } else {identity {
                    {
                        Zicl_Val objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $[self::ret $basetype objv\[i\] $rvalue\[i\]]
                        }
                        $robj = Zicl_BoxList(ziclNewList(objv, $arraylen));
                    }
                } }
            } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $rtype -> basetype arraylen arraylen2]} {
                identity {
                    {
                        Zicl_Val objv[$arraylen];
                        for (int i = 0; i < $arraylen; i++) {
                            $basetype* rrow = $rvalue[i];
                            Zicl_Val* objrow = &objv[i];
                            $[self::ret ${basetype}\[${arraylen2}\] *objrow rrow]
                        }
                        $robj = Zicl_BoxList(ziclNewList(objv, $arraylen));
                    }
            } } else {
                error "Unrecognized rtype $rtype"
            }
        }
    }

    cflags {-I./vendor/zicl/zig-out/include -I./}
    endcflags {}
}

# Registers a new argtype.
method C::argtype {self t h} {
    dict set self::argtypes $t [csubst {identity {$h}}]
}
# Looks up the argtype and returns C code to convert it.
method C::arg {self argtype argname shim} {
    csubst [eval [dict getdef $self::argtypes $argtype \
                      [dict get $self::argtypes default]]]
}

# Registers a new rtype.
method C::rtype {self t h} {
    dict set self::rtypes $t [csubst {identity {$h}}]
}
method C::ret {self rtype robj rvalue} {
    csubst [eval [dict getdef $self::rtypes $rtype \
                      [dict get $self::rtypes default]]]
}

method C::include {self h} {
    if {[string index $h 0] eq "<"} {
        lappend self::code "#include $h" :extend
    } else {
        lappend self::code "#include \"$h\"" :extend
    }
}

method C::addcode {self newcode {extendArg {:noextend}}} {
    lassign [vm source $newcode] filename line
    if {$filename ne ""} {
        set newcode [subst {
#line $line "$filename"
$newcode
}]
    }
    lappend self::code $newcode {*}$extendArg
    list
}

method C::define {self newvars} {
    lappend self::code $newvars :noextend

    regsub -all -line {/\*.*?\*/} $newvars "" newvars
    regsub -all -line {//.*$} $newvars "" newvars
    regsub -all {=[^;]*;} $newvars "" newvars
    set newvars [string map {";" ""} $newvars]

    foreach {vartype varname} $newvars {
        if {[dict exists $self::vars $varname]} {
            error "var already exists: $varname"
        }
        dict set self::vars $varname $vartype

        lappend self::code [subst {
            $vartype *${varname}_ptr() {
                return &$varname;
            }
        }] :noextend
    }
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
        self::argtype $newt [eval [dict getdef $self::argtypes $argtype \
                                       [dict get $self::argtypes default]]]
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

# Registers a hand-written object or capability type: `code` must define
# `${type}_VTable` (a `const Zicl_ObjVTable*` or `const Zicl_CapHeadVTable*`
# global initialized to a static vtable). `C::compile` emits `code`, and
# `C::extend` borrows this unit's `${type}_VTable` pointer via `dynlib lookup`
# so values and capabilities round-trip across units.
#
# `C::struct` is the generated-code path onto the same hook; this is the
# hand-written one, for a type whose marshaling `C::struct` can't express.
method C::objtype {self type code} {
    if {[dict exists $self::objtypes $type]} {
        error "C objtype: already registered: $type"
    }
    dict set self::objtypes $type $code
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
        set fieldname [lindex $fields $($i+1)]
        # Canonicalize type.
        lassign [typestyle $fieldtype $fieldname] fieldtype fieldname
        lappend fieldnames $fieldname
        lset fields $i $fieldtype
        lset fields $($i+1) $fieldname
    }

    self::include <string.h>
    dict set self::objtypes $type [csubst {
        extern const Zicl_ObjVTable* $[set type]_VTable;

        static inline $type* $[set type]_fromObj(const Zicl_Obj* objPtr) {
            return (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE)
                ? *(($type* const*)&objPtr->body_backing)
                : ($type*)&objPtr->body_backing;
        }

        static inline Zicl_Obj* $[set type]_allocObj($type** out_struct) {
            size_t body_size = (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) ? sizeof($type*) : sizeof($type);
            void* body = NULL;
            Zicl_Obj* obj = Zicl_NewObj($[set type]_VTable, body_size, &body);
            if (obj == NULL) return NULL;
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                $type* allocated = malloc(sizeof($type));
                *(($type**)body) = allocated;
                *out_struct = allocated;
            } else {
                *out_struct = ($type*)body;
            }
            return obj;
        }

        void $[set type]_freeIntRepProc(Zicl_Obj* objPtr) {
            $type* struct_ptr = $[set type]_fromObj(objPtr);
            $[foreachZiclValueField $fields "struct_ptr" {Zicl_DropRef(%V);}]
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) free(struct_ptr);
        }
        Zicl_Obj* $[set type]_dupIntRepProc(const Zicl_Obj* srcPtr) {
            $type* dest_struct = NULL;
            Zicl_Obj* new_object = $[set type]_allocObj(&dest_struct);
            if (new_object == NULL) return NULL;
            *dest_struct = *$[set type]_fromObj(srcPtr);
            (void)dest_struct; // unused if $fields has no Zicl_Val field
            $[foreachZiclValueField $fields "dest_struct" {%V = Zicl_Ref(%V);}]
            return new_object;
        }
        void $[set type]_makeCrossthreadProc(Zicl_Obj* objPtr) {
            $type* struct_ptr = $[set type]_fromObj(objPtr);
            (void)struct_ptr; // unused if $fields has no Zicl_Val field
            $[foreachZiclValueField $fields "struct_ptr" {Zicl_MakeCrossthread(%V);}]
        }
        int $[set type]_updateStringProc(Zicl_Obj* objPtr) {
            $type* struct_ptr = $[set type]_fromObj(objPtr);

            const char *format = "$[join [lmap fieldname $fieldnames {
                subst {$fieldname {%s}}
                }] { }]";
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_Val struct_$fieldname;
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
                subst {Zicl_DropRef(struct_$fieldname);}
            }] "\n"]
            return ZICL_OK;
        }
        int $[set type]_shimmerFrom(Zicl_Interp *interp, Zicl_Shim* shim, $type** out) {
            void* body = Zicl_AsObjBody(Zicl_Current(shim), $[set type]_VTable);
            if (body) {
                *out = (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) ? *($type**)body : ($type*)body;
                return ZICL_OK;
            }

            $type robj;
            $[join [lmap {fieldtype fieldname} $fields {
                csubst {
                    Zicl_OptVal obj_$fieldname;
                    __ENSURE_OK(Zicl_ShimDictGet(interp, shim, Zicl_InternStr("$fieldname"), &obj_$fieldname));
                    __ENSURE(Zicl_IsSome(obj_$fieldname));
                    Zicl_Shim shim_$fieldname = Zicl_NewShim(Zicl_Unwrap(obj_$fieldname));
                    defer { Zicl_ShimDiscardChanges(&shim_$fieldname); }
                    $[self::arg $fieldtype robj_$fieldname "&shim_$fieldname"]
                    $[if {[regexp {\[[^\]]*\]$} $fieldtype]} {
                        subst {memcpy(robj.$fieldname, robj_$fieldname, sizeof(robj.$fieldname));}
                    } else {
                        subst {robj.$fieldname = robj_$fieldname;}
                    }]
                }
            }] "\n"]

            void* new_body = Zicl_PrepareToShimmer(shim, $[set type]_VTable);
            if (sizeof($type) > ZICL_OBJECT_BODY_MAX_SIZE) {
                $type* allocated_struct = malloc(sizeof($type));
                *allocated_struct = robj;
                *(($type**)new_body) = allocated_struct;
                *out = allocated_struct;
            } else {
                *(($type*)new_body) = robj;
                *out = ($type*)new_body;
            }

            return ZICL_OK;
        }

        static const Zicl_ObjVTable $[set type]_vtable = {
            .is_c_vtable = true,
            .name = "$type",
            .duplicate = $[set type]_dupIntRepProc,
            .free_internal_rep = $[set type]_freeIntRepProc,
            .update_string = $[set type]_updateStringProc,
            .make_crossthread = $[set type]_makeCrossthreadProc,
            .enumerate_struct = NULL
        };
        const Zicl_ObjVTable* $[set type]_VTable = &$[set type]_vtable;
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
            $type* dest_struct = NULL;
            Zicl_Obj* obj = $[set type]_allocObj(&dest_struct);
            if (obj == NULL) folkZiclAssert(ZICL_OOM);
            *dest_struct = \$rvalue;
            $[foreachZiclValueField $fields {dest_struct} {%V = Zicl_Ref(%V);}]
            \$robj = Zicl_BoxObject(obj);
        }
    }]
}

method C::proc {self name arguments rtype body} {
    set cname [string map {":" "_" "!" "_"} $name]
    lassign [vm source $body] filename line
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
    if {$rtype eq "void"} {
        set saverv [subst {
            $cname ([join $argnames ", "]);
        }]
    } else {
        set saverv [subst {
            $rtype rvalue = $cname ([join $argnames ", "]);
            Zicl_Val robj;
            [self::ret $rtype robj rvalue]
            Zicl_SetResultOwning(interp, robj);
        }]
    }

    if {[dict exists $self::procs $name]} { error "C proc: Name collision: $name" }
    dict set self::procs $name rtype $rtype
    dict set self::procs $name arglist $arglist
    dict set self::procs $name code [subst {
        $rtype $cname ([join $arglist ", "]) {
            [if {$filename ne ""} {
                subst {#line $line "$filename"}
            } else {list}]
            $body
        }

        static int [set cname]_Cmd(Zicl_Interp* interp, int argc, Zicl_Shim *argv) {
            if (argc != 1 + [llength $loadargs]) {
                Zicl_SetResultString(interp, "Wrong number of arguments to $name", -1);
                return ZICL_ERR;
            }
            int __capCleanupBase = __capCleanup.count;
            bool didSetOnError = false;
            if (!__onErrorIsSet) {
                int __r = setjmp(__onError);
                __onErrorIsSet = true;
                didSetOnError = true;

                if (__r != 0) {
                    __onErrorIsSet = false;
                    __capCleanupRunTo(__capCleanupBase);
                    return ZICL_ERR;
                }
            }

            [join $loadargs "\n"]
            $saverv

            __capCleanupRunTo(__capCleanupBase);
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
        void ${cid}_register(Zicl_Interp* intp_raw) {
            interp = intp_raw;

            [join [lmap srcid $self::extends {
                subst {${srcid}_register(interp);}
            }] "\n"]

            [join [lmap name [dict keys $self::procs] {
                set cname [string map {":" "_" "!" "_"} $name]
                subst {Zicl_CreateCommand(interp, "${cid}::${name}", ${cname}_Cmd, "", 0, -1);}
            }] "\n"]
        }

        Zicl_Dict* Zicl_${cid}Init(Zicl_Interp* intp) {
            Zicl_Val __pairs\[$nProcs * 2\];
            int __n = 0;

            [join [lmap {type srcCap} $self::extendedObjtypes {
                set addr [dynlib lookup $srcCap ${type}_VTable]
                subst {${type}_VTable = *(__typeof__(${type}_VTable)*) ${addr}UL;}
            }] "\n"]

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

    set cfd [file open $cfile w]; stream write $cfd $sourcecode; close $cfd
    set ignoreUnresolved {}; if {$tcl_platform::os eq "linux"} {
        set ignoreUnresolved -Wl,--unresolved-symbols=ignore-all
    } elseif {$tcl_platform::os eq "darwin"} {
        set ignoreUnresolved -Wl,-undefined,dynamic_lookup
    }
    if {[__isTracyEnabled]} {
        lappend self::cflags -DTRACY_ENABLE=1 -I./vendor/tracy/public
    }
    set asan_flags {}
    if {[vm exists env::ASAN_ENABLE] && $env::ASAN_ENABLE ne ""} {
        set asan_flags "-fsanitize=address -fsanitize-recover=address"
    }
    set out [exec $self::compiler {*}$asan_flags -Wall \
                        {*}$($tcl_platform::os eq "linux" ? [list -Wno-alloc-size-larger-than] : [list]) \
                        -U_FORTIFY_SOURCE -O2 -march=native -g \
                        -fno-omit-frame-pointer -fPIC \
                        {*}$self::cflags $cfile -c -o [file rootname $cfile].o]
    if {[string trim $out] ne ""} {
        puts $out
    }

    exec $self::compiler {*}$asan_flags -shared $ignoreUnresolved \
        -O2 -o /tmp/$cid.so [file rootname $cfile].o \
        {*}$self::endcflags

    if {$noload} {
        # Return the name of the compiled file instead of loading it.
        return /tmp/$cid.so
    }

    set dynlibCap [load /tmp/$cid.so]
    set fns [dynlib fns $dynlibCap]
    dict set fns __dynlib $dynlibCap
    # Snapshot of this compilation's own type/proc/var registrations, so a
    # later, separate compilation unit can `cc::extend` this one -- see
    # `C::extend`.
    dict set fns __cinfo [dict create \
        cid $cid \
        argtypes $self::argtypes \
        rtypes $self::rtypes \
        objtypes $self::objtypes \
        procs $self::procs \
        vars $self::vars \
        code $self::code]
    return $fns
}

# Declares a function pointer named $destname (default: $srcname) pointing
# at $srclib's already-compiled $srcname, resolved via `dynlib lookup`
# against $srclib's __dynlib capability. Requires $srclib's proc's actual C
# function to be externally visible (see C::proc: it no longer declares
# these `static`, precisely so this can dlsym them).
method C::import {self srclib srcname {destname {}}} {
    if {$destname eq ""} { set destname $srcname }

    set srcinfo [dict get $srclib __cinfo]
    set srcCap [dict get $srclib __dynlib]
    set procinfo [dict get $srcinfo procs $srcname]
    set rtype [dict get $procinfo rtype]
    set arglist [dict get $procinfo arglist]

    set cname [string map {":" "_" "!" "_"} $srcname]
    set addr [dynlib lookup $srcCap $cname]
    self::addcode "$rtype (*$destname) ([join $arglist {, }]) = ($rtype (*) ([join $arglist {, }])) ${addr}UL;"
}

# Shares another compiled library's types, procs, and vars with this one, so
# both refer to the exact same underlying vtables/functions/globals instead
# of each independently (and incompatibly) reconstructing their own copies
# -- see `C::struct`'s per-type vtable and `Zicl_ResolveCapability`'s
# vtable-identity check for why that matters. Everything this needs (symbol
# addresses, via `dynlib lookup`; type/proc/var metadata, via $srclib's
# __cinfo -- see C::compile) is resolved right now, at this Tcl-eval time,
# and baked into the generated C as literal constants -- so `cc::extend`
# must run before `cc::compile`, same as any other cc:: registration.
method C::extend {self args} {
    set noprocs false
    foreach arg $args {
        if {$arg eq "-noprocs"} {
            set noprocs true
        } else {
            set srclib $arg
        }
    }
    set srcinfo [dict get $srclib __cinfo]
    set srcCap [dict get $srclib __dynlib]

    foreach {snippet extend} [dict get $srcinfo code] {
        # Stays :extend so a unit extending *this* one gets it too (a struct
        # typedef has to reach every unit that inherited its objtype code, not
        # just the first). The lsearch is what keeps a diamond from emitting
        # the same declaration twice.
        if {$extend eq ":extend" && [lsearch -exact $self::code $snippet] < 0} {
            lappend self::code $snippet :extend
        }
    }

    dict for {k v} [dict get $srcinfo argtypes] {
        if {![dict exists $self::argtypes $k]} { dict set self::argtypes $k $v }
    }
    dict for {k v} [dict get $srcinfo rtypes] {
        if {![dict exists $self::rtypes $k]} { dict set self::rtypes $k $v }
    }

    # Re-declare each objtype's struct/marshaling functions locally (needed
    # so this unit's own C code can use the type), but don't let this unit's
    # init construct its OWN vtable for it -- self::extendedObjtypes tells
    # C::compile's init codegen to instead borrow $srclib's existing vtable
    # via `dynlib lookup`, so values round-trip correctly between the two
    # units.
    dict for {objtype code} [dict get $srcinfo objtypes] {
        if {![dict exists $self::objtypes $objtype]} {
            dict set self::objtypes $objtype $code
            dict set self::extendedObjtypes $objtype $srcCap
        } elseif {![dict exists $self::extendedObjtypes $objtype]} {
            dict set self::extendedObjtypes $objtype $srcCap
        }
    }

    if {!$noprocs} {
        dict for {name _} [dict get $srcinfo procs] {
            self::import $srclib $name
        }
    }

    dict for {varname vartype} [dict get $srcinfo vars] {
        set addr [dynlib lookup $srcCap ${varname}_ptr]
        self::addcode "$vartype* (*${varname}_ptr)() = ($vartype* (*)()) ${addr}UL;"
    }

    # Chain $srclib's own per-thread command registration into this unit's,
    # so a thread that only ever touches the NEW library still gets
    # $srclib's commands (e.g. imageLib::slice) registered on itself too --
    # required since Zicl_RegisterLazyFn is per-interp-thread.
    set srcid [dict get $srcinfo cid]
    if {[lsearch $self::extends $srcid] < 0} {
        set addr [dynlib lookup $srcCap ${srcid}_register]
        self::addcode "void (*${srcid}_register)(Zicl_Interp*) = (void (*)(Zicl_Interp*)) ${addr}UL;"
        lappend self::extends $srcid
    }
}

C::addcode {
    typedef struct Buffer {
        Zicl_CapHead head;
        size_t size;
        uint8_t *data;
    } Buffer;
} :extend

C::objtype Buffer {
    extern const Zicl_CapHeadVTable* Buffer_VTable;

    static void Buffer_deinitBody(Zicl_CapHead* head) {
        Buffer* buf = Zicl_ContainerOf(head, Buffer, head);
        free(buf->data);
        buf->data = NULL;
        buf->size = 0;
    }

    static void Buffer_destroyBacking(Zicl_CapHead* head) {
        free(Zicl_ContainerOf(head, Buffer, head));
    }

    static const Zicl_CapHeadVTable Buffer_vtable = {
        .name = "buffer",
        .deinit_body = Buffer_deinitBody,
        .destroy_backing = Buffer_destroyBacking,
    };
    const Zicl_CapHeadVTable* Buffer_VTable = &Buffer_vtable;

    static inline Buffer* Buffer_unwrap(Zicl_Interp* interp, Zicl_Shim* shim) {
        Zicl_CapHead* head = NULL;
        __ENSURE_OK(Zicl_ResolveCap(interp, shim, Buffer_VTable, &head));
        __capCleanupDefer(head);
        return Zicl_ContainerOf(head, Buffer, head);
    }

    static inline Zicl_Val Buffer_wrap(Buffer* buf) {
        Zicl_Val out;
        folkZiclAssert(Zicl_CapNewReferencing(&buf->head, &out));
        Zicl_CapDropRef(&buf->head);
        return out;
    }

    static inline Buffer* bufferNewFromPtr(uint8_t* data, size_t size) {
        Buffer* buf = (Buffer*)malloc(sizeof(Buffer));
        if (!buf) folkZiclAssert(ZICL_OOM);
        buf->head = (Zicl_CapHead){ .vtable = Buffer_VTable };
        buf->size = size;
        buf->data = data;
        folkZiclAssert(Zicl_CapRegister(&buf->head));
        return buf;
    }

    static inline Buffer* bufferNew(size_t size) {
        uint8_t* data = (uint8_t*)malloc(size);
        if (!data && size > 0) folkZiclAssert(ZICL_OOM);
        return bufferNewFromPtr(data, size);
    }
}

C::argtype Buffer* {
    Buffer* $argname = Buffer_unwrap(interp, $shim);
}
C::rtype Buffer* {
    $robj = Buffer_wrap($rvalue);
}

# A C++ flavor of a C prototype. Defaults to the base `$C`, but takes any
# prototype linked off it (e.g. gpu.folk's `$Vulkan`) so a C++ module can
# still inherit that prototype's extra methods.
fn C++ {{proto {}}} {
    if {$proto eq {}} { set proto $C }
    set cpp [dict link $proto {}]
    set cpp::compiler c++
    cpp::addcflags -Wno-write-strings
    return $cpp
}
