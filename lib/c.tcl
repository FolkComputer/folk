proc csubst {s} {
    # much like subst, but you invoke a Tcl fn with $[whatever]
    # instead of [whatever]
    set result [list]
    for {set i 0} {$i < [string length $s]} {incr i} {
        set c [string index $s $i]
        switch $c {
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

namespace eval c {
    variable nextHandle 0
    proc create {} {
        variable nextHandle
        set handle "c[incr nextHandle]"
        uplevel [list namespace eval $handle {
            variable prelude {
                #include <tcl.h>
                #include <inttypes.h>
                #include <stdint.h>
                #include <stdbool.h>
                #include <setjmp.h>

                jmp_buf __onError;

                #define __ENSURE(EXPR) if (!(EXPR)) { Tcl_SetResult(interp, "failed to convert argument from Tcl to C in: " #EXPR, NULL); longjmp(__onError, 0); }
                #define __ENSURE_OK(EXPR) if ((EXPR) != TCL_OK) { longjmp(__onError, 0); }
            }
            variable code [list]
            variable objtypes [list]
            variable procs [dict create]

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

            # Tcl->C conversion logic, when a value is passed from Tcl
            # to a C function as an argument.
            variable argtypes {
                int { expr {{ int $argname; __ENSURE_OK(Tcl_GetIntFromObj(interp, $obj, &$argname)); }}}
                double { expr {{ double $argname; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $obj, &$argname)); }}}
                float { expr {{ double _$argname; __ENSURE_OK(Tcl_GetDoubleFromObj(interp, $obj, &_$argname)); float $argname = (float)_$argname; }}}
                bool { expr {{ int $argname; __ENSURE_OK(Tcl_GetIntFromObj(interp, $obj, &$argname)); }}}
                int32_t { expr {{ int $argname; __ENSURE_OK(Tcl_GetIntFromObj(interp, $obj, &$argname)); }}}
                char { expr {{
                    char $argname;
                    {
                        int _len_$argname;
                        char* _tmp_$argname = Tcl_GetStringFromObj($obj, &_len_$argname);
                        __ENSURE(_len_$argname >= 1);
                        $argname = _tmp_$argname[0];
                    }
                }}}
                size_t { expr {{ size_t $argname; __ENSURE_OK(Tcl_GetLongFromObj(interp, $obj, (long *)&$argname)); }}}
                intptr_t { expr {{ intptr_t $argname; __ENSURE_OK(Tcl_GetLongFromObj(interp, $obj, (long *)&$argname)); }}}
                uint16_t { expr {{ uint16_t $argname; __ENSURE_OK(Tcl_GetIntFromObj(interp, $obj, (int *)&$argname)); }}}
                uint32_t { expr {{ uint32_t $argname; __ENSURE(sscanf(Tcl_GetString($obj), "%"PRIu32, &$argname) == 1); }}}
                uint64_t { expr {{ uint64_t $argname; __ENSURE(sscanf(Tcl_GetString($obj), "%"PRIu64, &$argname) == 1); }}}
                char* { expr {{ char* $argname = Tcl_GetString($obj); }} }
                Tcl_Obj* { expr {{ Tcl_Obj* $argname = $obj; }}}
                default {
                    if {[string index $argtype end] == "*"} {
                        expr {{
                            $argtype $argname;
                            __ENSURE(sscanf(Tcl_GetString($obj), "($argtype) 0x%p", &$argname) == 1);
                        }}
                    } elseif {[regexp {(^[^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                        # note: arraylen can be ""
                        if {$basetype eq "char"} { expr {{
                            char $argname[$arraylen]; memcpy($argname, Tcl_GetString($obj), $arraylen);
                        }} } else { 
                            expr {{
                                int $[set argname]_objc;
                                Tcl_Obj** $[set argname]_objv;
                                __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));

                                $basetype $argname[$[set argname]_objc];
                                {
                                    for (int i = 0; i < $[set argname]_objc; i++) {
                                        $[arg $basetype ${argname}_i ${argname}_objv\[i\]]
                                        $argname[i] = $[set argname]_i;
                                    }
                                }
                            }} 
                        }
                    } elseif {[regexp {(^[^\[]+)\[(\d*)\]\[(\d*)\]$} $argtype -> basetype arraylen arraylen2]} {
                        expr {{
                            int $[set argname]_objc;
                            Tcl_Obj** $[set argname]_objv;
                            __ENSURE_OK(Tcl_ListObjGetElements(interp, $obj, &$[set argname]_objc, &$[set argname]_objv));

                            $basetype $argname[$[set argname]_objc][$arraylen2];
                            {
                                for (int i = 0; i < $[set argname]_objc; i++) {
                                    $[arg ${basetype}\[\] ${argname}_i ${argname}_objv\[i\]]
                                    memcpy(${argname}[i], ${argname}_i, sizeof(${argname}_i));
                                }
                            }
                        }}
                    } else {
                        error "Unrecognized argtype $argtype"
                    }
                }
            }
            ::proc argtype {t h} {
                variable argtypes
                set argtypes [linsert $argtypes 0 $t [csubst {expr {{$h}}}]]
            }
            ::proc arg {argtype argname obj} {
                variable argtypes
                csubst [switch $argtype $argtypes]
            }

            # C->Tcl conversion logic, when a value is returned from a
            # C function to Tcl.
            variable rtypes {
                int { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                int32_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                double { expr {{ $robj = Tcl_NewDoubleObj($rvalue); }}}
                float { expr {{ $robj = Tcl_NewDoubleObj($rvalue); }}}
                char { expr {{ $robj = Tcl_ObjPrintf("%c", $rvalue); }}}
                bool { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint8_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint16_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint32_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint64_t { expr {{ $robj = Tcl_NewLongObj($rvalue); }}}
                size_t { expr {{ $robj = Tcl_NewLongObj($rvalue); }}}
                intptr_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                char* { expr {{ $robj = Tcl_NewStringObj($rvalue, -1); }} }
                Tcl_Obj* { expr {{ $robj = $rvalue; }}}
                default {
                    if {[string index $rtype end] == "*"} {
                        expr {{ $robj = Tcl_ObjPrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue); }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                        if {$basetype eq "char"} { expr {{
                            $robj = Tcl_ObjPrintf("%s", $rvalue);
                        }} } else { expr {{
                            {
                                Tcl_Obj* objv[$arraylen];
                                for (int i = 0; i < $arraylen; i++) {
                                    $[ret $basetype objv\[i\] $rvalue\[i\]]
                                }
                                $robj = Tcl_NewListObj($arraylen, objv);
                            }
                        }} }
                    } else {
                        error "Unrecognized rtype $rtype"
                    }
                }
            }
            ::proc rtype {t h} {
                variable rtypes
                set rtypes [linsert $rtypes 0 $t [csubst {expr {{$h}}}]]
            }
            ::proc ret {rtype robj rvalue} {
                variable rtypes
                csubst [switch $rtype $rtypes]
            }

            ::proc typedef {t newt} {
                code "typedef $t $newt;"
                set argtype $t; set rtype $t
                variable argtypes
                argtype $newt [switch $argtype $argtypes]
                variable rtypes
                rtype $newt [switch $rtype $rtypes]
            }

            ::proc include {h} {
                variable code
                if {[string index $h 0] eq "<"} {
                    lappend code "#include $h"
                } else {
                    lappend code "#include \"$h\""
                }
            }
            ::proc linedirective {} {
                set frame [info frame -2]
                if {[dict exists $frame line] && [dict exists $frame file] &&
                    [dict get $frame line] >= 0} {
                    subst {#line [dict get $frame line] "[dict get $frame file]"}
                } else { list }
            }
            ::proc code {newcode} {
                variable code
                lappend code [subst {
                    [linedirective]
                    $newcode
                }]
                list
            }

            ::proc enum {type values} {
                variable code
                lappend code [subst {
                    typedef enum $type $type;
                    enum $type {$values};
                }]

                regsub -all {,} $values "" values
                variable argtypes; argtype $type [switch int $argtypes]
                variable rtypes; rtype $type [switch int $rtypes]
            }

            ::proc struct {type fields} {
                variable code
                lappend code [subst {
                    typedef struct $type $type;
                    struct $type {$fields};
                }]

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

                variable objtypes
                include <string.h>
                # ptrAndLongRep.value = 1 means the data is owned by
                # the Tcl_ObjType and should be freed by this
                # code. value = 0 means the data is owned externally
                # (by someone else like the statement store).
                lappend objtypes [csubst {
                    extern Tcl_ObjType $[set type]_ObjType;
                    void $[set type]_freeIntRepProc(Tcl_Obj *objPtr) {
                        if (objPtr->internalRep.ptrAndLongRep.value == 1) {
                            ckfree((char*)objPtr->internalRep.ptrAndLongRep.ptr);
                        }
                    }
                    void $[set type]_dupIntRepProc(Tcl_Obj *srcPtr, Tcl_Obj *dupPtr) {
                        dupPtr->internalRep.ptrAndLongRep.ptr = ckalloc(sizeof($type));
                        dupPtr->internalRep.ptrAndLongRep.value = 1;
                        memcpy(dupPtr->internalRep.ptrAndLongRep.ptr, srcPtr->internalRep.ptrAndLongRep.ptr, sizeof($type));
                    }
                    void $[set type]_updateStringProc(Tcl_Obj *objPtr) {
                        $[set type] *robj = objPtr->internalRep.ptrAndLongRep.ptr;

                        const char *format = "$[join [lmap fieldname $fieldnames {
                            subst {$fieldname {%s}}
                        }] { }]";
                        $[join [lmap {fieldtype fieldname} $fields {
                            csubst {
                                Tcl_Obj* robj_$fieldname;
                                $[ret $fieldtype robj_$fieldname robj->$fieldname]
                            }
                        }] "\n"]
                        objPtr->length = snprintf(NULL, 0, format, $[join [lmap fieldname $fieldnames {expr {"Tcl_GetString(robj_$fieldname)"}}] ", "]);
                        objPtr->bytes = ckalloc(objPtr->length + 1);
                        snprintf(objPtr->bytes, objPtr->length + 1, format, $[join [lmap fieldname $fieldnames {expr {"Tcl_GetString(robj_$fieldname)"}}] ", "]);
                    }
                    int $[set type]_setFromAnyProc(Tcl_Interp *interp, Tcl_Obj *objPtr) {
                        $[set type] *robj = ($[set type] *)ckalloc(sizeof($[set type]));
                        $[join [lmap {fieldtype fieldname} $fields {
                            csubst {
                                Tcl_Obj* obj_$fieldname;
                                Tcl_DictObjGet(interp, objPtr, Tcl_ObjPrintf("%s", "$fieldname"), &obj_$fieldname);
                                $[arg $fieldtype robj_$fieldname obj_${fieldname}]
                                memcpy(&robj->$fieldname, &robj_$fieldname, sizeof(robj->$fieldname));
                            }
                        }] "\n"]

                        objPtr->typePtr = &$[set type]_ObjType;
                        objPtr->internalRep.ptrAndLongRep.ptr = robj;
                        objPtr->internalRep.ptrAndLongRep.value = 1;
                        return TCL_OK;
                    }
                    Tcl_ObjType $[set type]_ObjType = (Tcl_ObjType) {
                        .name = "$type",
                        .freeIntRepProc = $[set type]_freeIntRepProc,
                        .dupIntRepProc = $[set type]_dupIntRepProc,
                        .updateStringProc = $[set type]_updateStringProc,
                        .setFromAnyProc = $[set type]_setFromAnyProc
                    };
                }]

                argtype $type [csubst {
                    __ENSURE_OK(Tcl_ConvertToType(interp, \$obj, &$[set type]_ObjType));
                    \$argtype \$argname;
                    \$argname = *(($type *)\$obj->internalRep.ptrAndLongRep.ptr);
                }]
                argtype $type* [csubst {
                    \$argtype \$argname;
                    if (\$obj->bytes != NULL && \$obj->bytes[0] == '(') {
                        // If it has a string repr and starts with (.
                        __ENSURE(sscanf(Tcl_GetString(\$obj), "(\$argtype) 0x%p", &\$argname) == 1);

                    } else {
                        // Otherwise, try to coerce from struct.
                        __ENSURE_OK(Tcl_ConvertToType(interp, \$obj, &$[set type]_ObjType));
                        \$argname = ($type *)\$obj->internalRep.ptrAndLongRep.ptr;
                    }
                }]

                rtype $type {
                    $robj = Tcl_NewObj();
                    $robj->bytes = NULL;
                    $robj->typePtr = &$[set rtype]_ObjType;
                    $robj->internalRep.ptrAndLongRep.ptr = ckalloc(sizeof($[set rtype]));
                    $robj->internalRep.ptrAndLongRep.value = 1;
                    memcpy($robj->internalRep.ptrAndLongRep.ptr, &$rvalue, sizeof($[set rtype]));
                }

                # Generate Tcl getter functions for each field:
                set ns [uplevel {namespace current}]::$type
                namespace eval $ns {}
                foreach {fieldtype fieldname} $fields {
                    try {
                        if {$fieldtype ne "Tcl_Obj*" &&
                            [regexp {([^\[]+)(?:\[(\d*)\]|\*)$} $fieldtype -> basefieldtype arraylen]} {
                            if {$basefieldtype eq "char"} {
                                proc ${ns}::$fieldname {Tcl_Interp* interp Tcl_Obj* obj} char* {
                                    __ENSURE_OK(Tcl_ConvertToType(interp, obj, &$[set type]_ObjType));
                                    return (($type *)obj->internalRep.ptrAndLongRep.ptr)->$fieldname;
                                }
                            } else {
                                proc ${ns}::${fieldname}_ptr {Tcl_Interp* interp Tcl_Obj* obj} $basefieldtype* {
                                    __ENSURE_OK(Tcl_ConvertToType(interp, obj, &$[set type]_ObjType));
                                    return (($type *)obj->internalRep.ptrAndLongRep.ptr)->$fieldname;
                                }
                                # If fieldtype is a pointer or an array,
                                # then make a getter that takes an index.
                                proc ${ns}::$fieldname {Tcl_Interp* interp Tcl_Obj* obj int idx} $basefieldtype {
                                    __ENSURE_OK(Tcl_ConvertToType(interp, obj, &$[set type]_ObjType));
                                    return (($type *)obj->internalRep.ptrAndLongRep.ptr)->$fieldname[idx];
                                }
                            }
                        } else {
                            proc ${ns}::$fieldname {Tcl_Interp* interp Tcl_Obj* obj} $fieldtype {
                                __ENSURE_OK(Tcl_ConvertToType(interp, obj, &$[set type]_ObjType));
                                return (($type *)obj->internalRep.ptrAndLongRep.ptr)->$fieldname;
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

            ::proc "proc" {name args rtype body} {
                set cname [string map {":" "_"} $name]
                set body [uplevel [list csubst $body]]

                # puts "$name $args $rtype $body"
                set arglist [list]
                set argnames [list]
                set loadargs [list]
                foreach {argtype argname} $args {
                    lassign [typestyle $argtype $argname] argtype argname
                    lappend arglist [join [cstyle $argtype $argname] " "]
                    lappend argnames $argname

                    if {$argtype == "Tcl_Interp*" && $argname == "interp"} { continue }

                    set obj [subst {objv\[1 + [llength $loadargs]\]}]
                    lappend loadargs [arg {*}[typestyle $argtype $argname] $obj]
                }
                if {$rtype == "void"} {
                    set saverv [subst {
                        $cname ([join $argnames ", "]);
                        return TCL_OK;
                    }]
                } else {
                    set saverv [subst {
                        $rtype rvalue = $cname ([join $argnames ", "]);
                        Tcl_Obj* robj;
                        [ret $rtype robj rvalue]
                        Tcl_SetObjResult(interp, robj);
                        return TCL_OK;
                    }]
                }

                variable procs
                if {[dict exists $procs $name]} { error "Name collision: $name" }
                dict set procs $name rtype $rtype
                dict set procs $name arglist $arglist
                dict set procs $name ns [uplevel {namespace current}]
                dict set procs $name code [subst {
                    static $rtype $cname ([join $arglist ", "]) {
                        [linedirective]
                        $body
                    }

                    static int [set cname]_Cmd(ClientData cdata, Tcl_Interp* interp, int objc, Tcl_Obj* const objv\[\]) {
                        if (objc != 1 + [llength $loadargs]) {
                            Tcl_SetResult(interp, "Wrong number of arguments to $name", NULL);
                            return TCL_ERROR;
                        }
                        int r = setjmp(__onError);
                        if (r != 0) { return TCL_ERROR; }

                        [join $loadargs "\n"]
                        $saverv
                    }
                }]
            }

            variable cflags [switch $tcl_platform(os) {
                Darwin { expr { [file exists "$::tcl_library/../../Tcl"] ?
                                [list -I$::tcl_library/../../Headers $::tcl_library/../../Tcl] :
                                [list -I$::tcl_library/../../include \
                                       $::tcl_library/../libtcl8.6.dylib \
                                       -mmacosx-version-min=$tcl_platform(osVersion) \
                                ]
                            } }
                Linux { list -I/usr/include/tcl8.6 -ltcl8.6 }
            }]
            ::proc cflags {args} { variable cflags; lappend cflags {*}$args }
            ::proc compile {} {
                variable prelude
                variable code
                variable objtypes
                variable procs
                variable cflags

                set init [subst {
                    int Cfile_Init(Tcl_Interp* interp) {
                        [join [lmap name [dict keys $procs] {
                            set cname [string map {":" "_"} $name]
                            set tclname $name
                            if {[string first :: $tclname] != 0} {
                                set tclname [dict get $procs $name ns]::$name
                            }
                            # puts "Creating C command: $tclname"
                            csubst {
                                char $[set cname]_addr[100]; snprintf($[set cname]_addr, 100, "%p", $cname);
                                Tcl_SetVar(interp, "$[namespace current]::$[set cname]_addr", $[set cname]_addr, 0);

                                Tcl_CreateObjCommand(interp, "$tclname", $[set cname]_Cmd, NULL, NULL);
                            }
                        }] "\n"]
                        return TCL_OK;
                    }
                }]
                set sourcecode [join [list \
                                          $prelude \
                                          {*}$code \
                                          {*}$objtypes \
                                          {*}[lmap p [dict values $procs] {dict get $p code}] \
                                          $init \
                                         ] "\n"]

                # puts "=====================\n$sourcecode\n====================="

                set cfd [file tempfile cfile cfile.c]; puts $cfd $sourcecode; close $cfd
                exec cc -Wall -g -shared -fno-omit-frame-pointer -fPIC {*}$cflags $cfile -o [file rootname $cfile][info sharedlibextension]
                load [file rootname $cfile][info sharedlibextension] cfile
            }
            ::proc import {scc sname as dest} {
                set scc [namespace origin [namespace qualifiers $scc]::[set $scc]]
                set procinfo [dict get [set ${scc}::procs] $sname]
                set rtype [dict get $procinfo rtype]
                set arglist [dict get $procinfo arglist]
                set addr [set [set scc]::[set sname]_addr]
                code "$rtype (*$dest) ([join $arglist {, }]) = ($rtype (*) ([join $arglist {, }])) $addr;"
            }

            namespace export *
            namespace ensemble create
        }]
        return $handle
    }

    set loader [create]
    $loader include <dlfcn.h>
    $loader proc loadlibImpl {char* filename} void* {
        // TODO: report dlerror error
        // TODO: better shadowing handling
        return dlopen(filename, RTLD_NOW | RTLD_GLOBAL);
    }
    $loader proc loadlibError {} char* { return dlerror(); }
    $loader compile
    proc loadlib {filename} {
        if {[loadlibImpl $filename] == "(void*) 0x0"} {
            error "c loadlib: Failed to dlopen $filename: [loadlibError]"
        }
    }
    proc loadlibLd {libname} {
        set candidates [split [exec /usr/sbin/ldconfig -p | grep $libname] "\n"]
        if {[llength $candidates] == 0} {
            error "c loadlibLd: Could not find library $libname"
        } elseif {[llength $candidates] > 1} {
            # Is it greater than 1? if so, filter by arch
            set candidates [lsearch -all -inline $candidates *$::tcl_platform(machine)*]
        }
        loadlib [lindex $candidates 0 end]
    }

    namespace export *
    namespace ensemble create
}
