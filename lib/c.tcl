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
                if {[regexp {^(?:[A-Za-z0-9_]|::)+} $tail varname]} {
                    lappend result [uplevel [list set $varname]]
                    incr i [string length $varname]
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
            variable procs [dict create]

            variable argtypes {
                int { expr {{ Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                uint32_t { expr {{ Tcl_GetLongFromObj(interp, $obj, &$argname); }}}
                size_t { expr {{ Tcl_GetLongFromObj(interp, $obj, &$argname); }}}
                char* { expr {{ $argname = Tcl_GetString($obj); }} }
                Tcl_Obj* { expr {{ $argname = $obj; }}}
                default {
                    if {[string index $argtype end] == "*"} {
                        expr {{
                            if (sscanf(Tcl_GetString($obj), "($argtype) 0x%p", &$argname) != 1) {
                                return TCL_ERROR;
                            }
                        }}
                    } elseif {[regexp {([^\[]+)\[(\d*)\]$} $argtype -> basetype arraylen]} {
                        expr {{
                            $basetype $argname[$arraylen];

                            int objc; Tcl_Obj* objv;
                            Tcl_ListObjGetElements(interp, $obj, &objc, &objv);
                            for (int i = 0; i < $arraylen; i++) {
                                $[apply {{argtypes obj argtype argname} \
                                             {csubst [switch $argtype $argtypes]}} \
                                        $argtypes objv\[i\] $basetype $argname\[i\]]
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

            variable rtypes {
                int { expr {{
                    Tcl_SetObjResult(interp, Tcl_NewIntObj(rv));
                    return TCL_OK;
                }}}
                char* { expr {{ Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s", rv)); return TCL_OK; }} }
                Tcl_Obj* { expr {{
                    Tcl_SetObjResult(interp, rv);
                    return TCL_OK;
                }}}
                default {
                    if {[string index $rtype end] == "*"} {
                        expr {{
                            Tcl_SetObjResult(interp, Tcl_ObjPrintf("($rtype) 0x%" PRIxPTR, (uintptr_t) rv));
                            return TCL_OK;
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

            ::proc include {h} {
                variable code
                lappend code "#include $h"
            }
            ::proc code {newcode} { variable code; lappend code $newcode; list }
            ::proc typedef {existingtype alias} {
                variable code; lappend code "typedef $existingtype $alias;"
                variable argtypes
                if {[dict exists $argtypes $existingtype]} {
                    set argtypes [linsert $argtypes 0 $alias [dict get $argtypes $existingtype]]
                }
                variable rtypes
                if {[dict exists $rtypes $existingtype]} {
                    set rtypes [linsert $rtypes 0 $alias [dict get $rtypes $existingtype]]
                }
            }
            ::proc struct {type fields} {
                variable code
                lappend code [subst {
                    typedef struct $type $type;
                    struct $type {
                        $fields
                    };
                }]

                puts "struct type $type: $fields"
                variable argtypes
                set argscripts [list]
                dict for {fieldtype fieldname} $fields {
                    regexp {([^\[]+)(\[\d*\])?;$} $fieldname -> fieldname arraysuffix
                    lappend argscripts [csubst {
                        Tcl_Obj* fieldobj;
                        Tcl_DictObjGet(interp, \$obj, Tcl_ObjPrintf("%s", "$fieldname"), &fieldobj);
                    }]
                    lappend argscripts [apply {{argtypes obj argtype argname} \
                                                   {csubst [switch $argtype $argtypes]}} \
                                            $argtypes fieldobj $fieldtype$arraysuffix $fieldname]
                }
                puts "argscript for $type: [join $argscripts "\n"]"
                set argtypes [linsert $argtypes 0 $type [list expr [list [join $argscripts "\n"]]]]
                puts "argtypes $argtypes"
                # expr {{
                #     if {}
                # }}

                # variable argtypes
                # set argtypes [linsert $argtypes 0 $type [subst {expr {{$h}}}]]
            }

            ::proc "proc" {name args rtype body} {
                # puts "$name $args $rtype $body"
                variable argtypes
                variable rtypes

                set arglist [list]
                set argnames [list]
                set loadargs [list]
                for {set i 0} {$i < [llength $args]} {incr i 2} {
                    set argtype [lindex $args $i]
                    set argname [lindex $args [expr {$i+1}]]
                    lappend arglist "$argtype $argname"
                    lappend argnames $argname

                    if {$argtype == "Tcl_Interp*" && $argname == "interp"} { continue }

                    set obj [subst {objv\[1 + [llength $loadargs]\]}]
                    lappend loadargs [subst {
                        $argtype $argname;
                        [csubst [switch $argtype $argtypes]]
                    }]
                }
                if {$rtype == "void"} {
                    set saverv [subst {
                        $name ([join $argnames ", "]);
                        return TCL_OK;
                    }]
                } else {
                    set saverv [subst {
                        $rtype rv = $name ([join $argnames ", "]);
                        [subst [switch $rtype $rtypes]]
                    }]
                }

                set uniquename [string map {":" "_"} [uplevel [list namespace current]]]__$name
                variable procs
                dict set procs $name [subst {
                    static $rtype $name ([join $arglist ", "]) {
                        $body
                    }

                    static int [set name]_Cmd(ClientData cdata, Tcl_Interp* interp, int objc, Tcl_Obj* const objv\[\]) {
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
                                [list -I$::tcl_library/../../include $::tcl_library/../libtcl8.6.dylib]
                            } }
                Linux { list -I/usr/include/tcl8.6 -ltcl8.6 }
            }]
            ::proc cflags {args} { variable cflags; lappend cflags {*}$args }
            ::proc compile {} {
                variable prelude
                variable code
                variable procs
                variable cflags

                set init [subst {
                    int Cfile_Init(Tcl_Interp* interp) {
                        [join [lmap name [dict keys $procs] { subst {
                            Tcl_CreateObjCommand(interp, "[uplevel [list namespace current]]::$name", [set name]_Cmd, NULL, NULL);
                        }}] "\n"]
                        return TCL_OK;
                    }
                }]
                set sourcecode [join [list \
                                          $prelude \
                                          {*}$code \
                                          {*}[dict values $procs] \
                                          $init \
                                         ] "\n"]

                # puts "=====================\n$sourcecode\n====================="

                set cfd [file tempfile cfile cfile.c]; puts $cfd $sourcecode; close $cfd
                exec cc -Wall -g -shared -fPIC {*}$cflags $cfile -o [file rootname $cfile][info sharedlibextension]
                load [file rootname $cfile][info sharedlibextension] cfile
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

# FIXME: legacy critcl stuff below:

if {![info exists ::livecprocs]} {set ::livecprocs [dict create]}
proc livecproc {name args} {
    if {[dict exists $::livecprocs $name $args]} {
        # promote this proc
        dict set ::livecprocs $name [dict create $args [dict get $::livecprocs $name $args]]
    } else { ;# compile
        critcl::cproc $name$::stepCount {*}$args
        dict set ::livecprocs $name $args $name$::stepCount
    }
    proc $name {args} {
        set name [lindex [info level 0] 0]
        [lindex [dict values [dict get $::livecprocs $name]] end] {*}$args
    }
}
