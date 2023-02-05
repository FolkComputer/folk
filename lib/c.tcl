proc csubst {s} {
    # much like subst, but you invoke a Tcl fn with $[whatever]
    # instead of [whatever]
    set result [list]
    for {set i 0} {$i < [string length $s]} {incr i} {
        set c [string index $s $i]
        switch $c {
            "\\" {incr i; lappend result [string index $s $i]}
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

            variable argtypes {
                int { expr {{ int $argname; Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                size_t { expr {{ size_t $argname; Tcl_GetLongFromObj(interp, $obj, (long *)&$argname); }}}
                uint16_t { expr {{ uint16_t $argname; Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                uint32_t { expr {{ uint32_t $argname; sscanf(Tcl_GetString($obj), "%"PRIu32, &$argname); }}}
                uint64_t { expr {{ uint64_t $argname; sscanf(Tcl_GetString($obj), "%"PRIu64, &$argname); }}}
                char* { expr {{ char* $argname = Tcl_GetString($obj); }} }
                Tcl_Obj* { expr {{ Tcl_Obj* $argname = $obj; }}}
                default {
                    if {[string index $argtype end] == "*"} {
                        expr {{
                            $argtype $argname;
                            if (sscanf(Tcl_GetString($obj), "($argtype) 0x%p", &$argname) != 1) {
                                return TCL_ERROR;
                            }
                        }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                        # note: arraylen can be ""
                        expr {{
                            int ${argname}_objc; Tcl_Obj** ${argname}_objv;
                            Tcl_ListObjGetElements(interp, $obj, &${argname}_objc, &${argname}_objv);
                            $basetype $argname\[${argname}_objc\];
                            {
                                for (int i = 0; i < ${argname}_objc; i++) {
                                    $[arg $basetype ${argname}_i ${argname}_objv\[i\]]
                                    $argname\[i\] = ${argname}_i;
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

            variable rtypes {
                int { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                bool { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint16_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                uint32_t { expr {{ $robj = Tcl_NewIntObj($rvalue); }}}
                size_t { expr {{ $robj = Tcl_NewLongObj($rvalue); }}}
                char* { expr {{ $robj = Tcl_ObjPrintf("%s", $rvalue); }} }
                Tcl_Obj* { expr {{ $robj = $rvalue; }}}
                default {
                    if {[string index $rtype end] == "*"} {
                        expr {{ $robj = Tcl_ObjPrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) $rvalue); }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $rtype -> basetype arraylen]} {
                        expr {{
                            {
                                Tcl_Obj* objv[$arraylen];
                                for (int i = 0; i < $arraylen; i++) {
                                    $[ret $basetype objv\[i\] $rvalue\[i\]]
                                }
                                $robj = Tcl_NewListObj($arraylen, objv);
                            }
                        }}
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
                lappend code "#include $h"
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
                # puts "FIELDS $fields"

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
                lappend objtypes [csubst {
                    void $[set type]_freeIntRepProc(Tcl_Obj *objPtr) {
                    }
                    void $[set type]_dupIntRepProc(Tcl_Obj *srcPtr, Tcl_Obj *dupPtr) {
                        dupPtr->internalRep.otherValuePtr = ckalloc(sizeof($type));
                        memcpy(dupPtr->internalRep.otherValuePtr, srcPtr->internalRep.otherValuePtr, sizeof($type));
                    }
                    void $[set type]_updateStringProc(Tcl_Obj *objPtr) {
                        $[set type] *robj = objPtr->internalRep.otherValuePtr;

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
                        return TCL_ERROR;
                    }
                    Tcl_ObjType $[set type]_ObjType = (Tcl_ObjType) {
                        .name = "$type",
                        .freeIntRepProc = $[set type]_freeIntRepProc,
                        .dupIntRepProc = $[set type]_dupIntRepProc,
                        .updateStringProc = $[set type]_updateStringProc,
                        .setFromAnyProc = $[set type]_setFromAnyProc
                    };
                }]

                variable argtypes
                set argscripts [list] ;# TODO: return a dictionary
                foreach {fieldtype fieldname} $fields {
                    lappend argscripts [csubst {
                        Tcl_Obj* obj_$fieldname;
                        Tcl_DictObjGet(interp, \$obj, Tcl_ObjPrintf("%s", "$fieldname"), &obj_$fieldname);
                    }]
                    lappend argscripts [arg $fieldtype \$argname.$fieldname obj_$fieldname]
                }
                argtype $type [list expr [list [join $argscripts "\n"]]]

                variable rtypes
                rtype $type {
                    $robj = ckalloc(sizeof(struct Tcl_Obj));
                    $robj->bytes = NULL;
                    $robj->typePtr = &$[set rtype]_ObjType;
                    $robj->internalRep.otherValuePtr = ckalloc(sizeof($[set rtype]));
                    memcpy($robj->internalRep.otherValuePtr, &$rvalue, sizeof($[set rtype]));
                }
            }

            ::proc "proc" {name args rtype body} {
                set cname [string map {":" "_"} $name]

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
                exec cc -Wall -g -shared -fPIC {*}$cflags $cfile -o [file rootname $cfile][info sharedlibextension]
                load [file rootname $cfile][info sharedlibextension] cfile
            }
            ::proc import {scc sname as dest} {
                set scc [namespace qualifiers $scc]::[set $scc]
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
