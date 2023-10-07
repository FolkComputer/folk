proc csubst {s} {
    # much like subst, but you invoke a Tcl fn with $[whatever]
    # instead of [whatever]
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

namespace eval c {
    variable nextHandle 0
    proc create {} {
        variable nextHandle
        set handle "c[incr nextHandle]"
        uplevel [list namespace eval $handle {
            variable prelude {
                #include <jim.h>
                #include <inttypes.h>
                #include <stdint.h>
                #include <stdbool.h>
                #include <stdio.h>
                #include <setjmp.h>

                jmp_buf __onError;
                Jim_Interp* interp;

                #define __ENSURE(EXPR) if (!(EXPR)) { Jim_SetResultFormatted(interp, "failed to convert argument from Tcl to C in: " #EXPR); longjmp(__onError, 0); }
                #define __ENSURE_OK(EXPR) if ((EXPR) != JIM_OK) { longjmp(__onError, 0); }

                Jim_Obj* Jim_ObjPrintf(Jim_Interp* interp, const char* format, ...) {
                    va_list args;
                    va_start(args, format);
                    char buf[10000]; vsnprintf(buf, 10000, format, args);
                    va_end(args);
                    return Jim_NewStringObj(interp, buf, -1);
                }
            }
            variable code [list]
            variable objtypes [list]
            variable procs [dict create]

            ::proc cstyle {type name} {
                if {[regexp {([^\[]+)(\[\d*\])$} $type -> basetype arraysuffix]} {
                    list $basetype $name$arraysuffix
                } else {
                    list $type $name
                }
            }
            ::proc typestyle {type name} {
                if {[regexp {([^\[]+)(\[\d*\])$} $name -> basename arraysuffix]} {
                    list $type$arraysuffix $basename
                } else {
                    list $type $name
                }
            }

            # Tcl->C conversion logic, when a value is passed from Tcl
            # to a C function as an argument.
            variable argtypes {
                int { expr {{ int $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, (long*) &$argname)); }}}
                double { expr {{ double $argname; __ENSURE_OK(Jim_GetDouble(interp, $obj, &$argname)); }}}
                float { expr {{ double _$argname; __ENSURE_OK(Jim_GetDouble(interp, $obj, &_$argname)); float $argname = (float)_$argname; }}}
                bool { expr {{ int $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, &$argname)); }}}
                int32_t { expr {{ int $argname; __ENSURE_OK(Jim_GetLong(interp, $obj, &$argname)); }}}
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
                uint32_t { expr {{ uint32_t $argname; __ENSURE(sscanf(Jim_String($obj), "%"PRIu32, &$argname) == 1); }}}
                uint64_t { expr {{ uint64_t $argname; __ENSURE(sscanf(Jim_String($obj), "%"PRIu64, &$argname) == 1); }}}
                char* { expr {{ char* $argname = (char*) Jim_String($obj); }} }
                Jim_Obj* { expr {{ Jim_Obj* $argname = $obj; }}}
                default {
                    if {[string index $argtype end] == "*"} {
                        expr {{
                            $argtype $argname;
                            __ENSURE(sscanf(Jim_String($obj), "($argtype) 0x%p", &$argname) == 1);
                        }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                        # note: arraylen can be ""
                        if {$basetype eq "char"} { expr {{
                            char $argname[$arraylen]; memcpy($argname, Jim_String($obj), $arraylen);
                        }} } else { expr {{
                            int $[set argname]_objc = Jim_ListLength(interp, $obj);
                            $basetype $argname[$[set argname]_objc];
                            {
                                for (int i = 0; i < $[set argname]_objc; i++) {
                                    $[arg $basetype ${argname}_i "Jim_ListGetIndex(interp, $obj, i)"]
                                    $argname[i] = $[set argname]_i;
                                }
                            }
                        }} }
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
                int { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                int32_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                double { expr {{ $robj = Jim_NewDoubleObj(interp, $rvalue); }}}
                float { expr {{ $robj = Jim_NewDoubleObj(interp, $rvalue); }}}
                char { expr {{ $robj = Jim_NewStringObj(&$rvalue, 1); }}}
                bool { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                uint8_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                uint16_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                uint32_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                uint64_t { expr {{ $robj = Jim_NewLongObj(interp, $rvalue); }}}
                size_t { expr {{ $robj = Jim_NewLongObj(interp, $rvalue); }}}
                intptr_t { expr {{ $robj = Jim_NewIntObj(interp, $rvalue); }}}
                char* { expr {{ $robj = Jim_NewStringObj(interp, $rvalue, -1); }} }
                Jim_Obj* { expr {{ $robj = $rvalue; }}}
                default {
                    if {[string index $rtype end] == "*"} {
                        expr {{ $robj = Jim_ObjPrintf(interp, "($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue); }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                        if {$basetype eq "char"} { expr {{
                            $robj = Jim_ObjPrintf(interp, "%s", $rvalue);
                        }} } else { expr {{
                            {
                                Jim_Obj* objv[$arraylen];
                                for (int i = 0; i < $arraylen; i++) {
                                    $[ret $basetype objv\[i\] $rvalue\[i\]]
                                }
                                $robj = Jim_NewListObj(interp, $arraylen, objv);
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
                    #subst {#line [dict get $frame line] "[dict get $frame file]"}
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
                # the Jim_ObjType and should be freed by this
                # code. value = 0 means the data is owned externally
                # (by someone else like the statement store).
                lappend objtypes [csubst {
                    extern Jim_ObjType $[set type]_ObjType;
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
                        $[set type] *robj = objPtr->internalRep.ptrIntValue.ptr;

                        const char *format = "$[join [lmap fieldname $fieldnames {
                            subst {$fieldname {%s}}
                        }] { }]";
                        $[join [lmap {fieldtype fieldname} $fields {
                            csubst {
                                Jim_Obj* robj_$fieldname;
                                $[ret $fieldtype robj_$fieldname robj->$fieldname]
                            }
                        }] "\n"]
                        objPtr->length = snprintf(NULL, 0, format, $[join [lmap fieldname $fieldnames {expr {"Jim_String(robj_$fieldname)"}}] ", "]);
                        objPtr->bytes = malloc(objPtr->length + 1);
                        snprintf(objPtr->bytes, objPtr->length + 1, format, $[join [lmap fieldname $fieldnames {expr {"Jim_String(robj_$fieldname)"}}] ", "]);
                    }
                    int $[set type]_setFromAnyProc(Jim_Interp *interp, Jim_Obj *objPtr) {
                        $[set type] *robj = ($[set type] *)malloc(sizeof($[set type]));
                        $[join [lmap {fieldtype fieldname} $fields {
                            csubst {
                                Jim_Obj* obj_$fieldname;
                                Jim_DictKey(interp, objPtr, Jim_ObjPrintf(interp, "%s", "$fieldname"), &obj_$fieldname, 0);
                                $[arg $fieldtype robj_$fieldname obj_${fieldname}]
                                memcpy(&robj->$fieldname, &robj_$fieldname, sizeof(robj->$fieldname));
                            }
                        }] "\n"]

                        objPtr->typePtr = &$[set type]_ObjType;
                        objPtr->internalRep.ptrIntValue.ptr = robj;
                        objPtr->internalRep.ptrIntValue.int1 = 1;
                        return JIM_OK;
                    }
                    Jim_ObjType $[set type]_ObjType = (Jim_ObjType) {
                        .name = "$type",
                        .freeIntRepProc = $[set type]_freeIntRepProc,
                        .dupIntRepProc = $[set type]_dupIntRepProc,
                        .updateStringProc = $[set type]_updateStringProc,
//                        .setFromAnyProc = $[set type]_setFromAnyProc
                    };
                }]

                argtype $type [csubst {
                    __ENSURE_OK($[set type]_setFromAnyProc(interp, \$obj));
                    \$argtype \$argname;
                    \$argname = *(($type *)\$obj->internalRep.ptrIntValue.ptr);
                }]

                rtype $type {
                    $robj = Jim_NewObj(interp);
                    $robj->bytes = NULL;
                    $robj->typePtr = &$[set rtype]_ObjType;
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
                            [regexp {([^\[]+)(?:\[(\d*)\]|\*)$} $fieldtype -> basefieldtype arraylen]} {
                            if {$basefieldtype eq "char"} {
                                proc ${ns}::$fieldname {Jim_Interp* interp Jim_Obj* obj} char* {
                                    __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                                    return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                                }
                            } else {
                                proc ${ns}::${fieldname}_ptr {Jim_Interp* interp Jim_Obj* obj} $basefieldtype* {
                                    __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                                    return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname;
                                }
                                # If fieldtype is a pointer or an array,
                                # then make a getter that takes an index.
                                proc ${ns}::$fieldname {Jim_Interp* interp Jim_Obj* obj int idx} $basefieldtype {
                                    __ENSURE_OK($[set type]_setFromAnyProc(interp, obj));
                                    return (($type *)obj->internalRep.ptrIntValue.ptr)->$fieldname[idx];
                                }
                            }
                        } else {
                            proc ${ns}::$fieldname {Jim_Interp* interp Jim_Obj* obj} $fieldtype {
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

            ::proc "proc" {name arguments rtype body} {
                set cname [string map {":" "_"} $name]
                set body [uplevel [list csubst $body]]

                # puts "$name $args $rtype $body"
                set arglist [list]
                set argnames [list]
                set loadargs [list]
                foreach {argtype argname} $arguments {
                    lassign [typestyle $argtype $argname] argtype argname
                    lappend arglist [join [cstyle $argtype $argname] " "]
                    lappend argnames $argname

                    if {$argtype == "Jim_Interp*" && $argname == "interp"} { continue }

                    set obj [subst {objv\[1 + [llength $loadargs]\]}]
                    lappend loadargs [arg {*}[typestyle $argtype $argname] $obj]
                }
                if {$rtype == "void"} {
                    set saverv [subst {
                        $cname ([join $argnames ", "]);
                        return JIM_OK;
                    }]
                } else {
                    set saverv [subst {
                        $rtype rvalue = $cname ([join $argnames ", "]);
                        Jim_Obj* robj;
                        [ret $rtype robj rvalue]
                        Jim_SetResult(interp, robj);
                        return JIM_OK;
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

                    static int [set cname]_Cmd(Jim_Interp* interp, int objc, Jim_Obj* const objv\[\]) {
                        if (objc != 1 + [llength $loadargs]) {
                            Jim_SetResultFormatted(interp, "Wrong number of arguments to $name");
                            return JIM_ERR;
                        }
                        int r = setjmp(__onError);
                        if (r != 0) { return JIM_ERR; }

                        [join $loadargs "\n"]
                        $saverv
                    }
                }]
            }

            variable cflags [list -I./vendor/jimtcl -Wl,-undefined,dynamic_lookup]
            ::proc cflags {args} { variable cflags; lappend cflags {*}$args }
            ::proc compile {} {
                variable prelude
                variable code
                variable objtypes
                variable procs
                variable cflags

                set cfile [file tempfile /tmp/cfileXXXXXX].c

                set init [subst {
                    int Jim_[file rootname [file tail $cfile]]Init(Jim_Interp* intp) {
                        interp = intp;

                        [join [lmap name [dict keys $procs] {
                            set cname [string map {":" "_"} $name]
                            set tclname $name
                            if {[string first :: $tclname] != 0} {
                                set tclname [dict get $procs $name ns]::$name
                            }
                            # puts "Creating C command: $tclname"
                            csubst {
                                char $[set cname]_addr[100]; snprintf($[set cname]_addr, 100, "%p", $cname);
                                Jim_SetVariableStrWithStr(interp, "$[namespace current]::$[set cname]_addr", $[set cname]_addr);

                                Jim_CreateCommand(interp, "$tclname", $[set cname]_Cmd, NULL, NULL);
                            }
                        }] "\n"]
                        return JIM_OK;
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

                set cfd [open $cfile w]; puts $cfd $sourcecode; close $cfd
                exec cc -Wall -g -shared -fno-omit-frame-pointer -fPIC {*}$cflags $cfile -o [file rootname $cfile].so
                load [file rootname $cfile].so cfile
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
            error "Failed to dlopen $filename: [loadlibError]"
        }
    }

    namespace export *
    namespace ensemble create
}
