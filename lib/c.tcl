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
                char* { expr {{ $argname = Tcl_GetString($obj); }} }
                Tcl_Obj* { expr {{ $argname = $obj; }}}
                default {
                    if {[string index $argtype end] == "*"} {
                        expr {{
                            if (sscanf(Tcl_GetString($obj), "($argtype) 0x%p", &$argname) != 1) {
                                return TCL_ERROR;
                            }
                        }}
                    } else {
                        error "Unrecognized argtype $argtype"
                    }
                }
            }
            ::proc argtype {t h} {
                variable argtypes
                set argtypes [linsert $argtypes 0 $t [subst {expr {{$h}}}]]
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
                set rtypes [linsert $rtypes 0 $t [subst {expr {{$h}}}]]
            }

            ::proc include {h} {
                variable code
                lappend code "#include $h"
            }
            ::proc code {newcode} { variable code; lappend code $newcode; list }
            ::proc struct {type fields} {
                variable code
                lappend code [subst {
                    typedef struct $type $type;
                    struct $type {
                        $fields
                    };
                }]
            }

            ::proc "proc" {name args rtype body} {
                set cname [string map {":" "_"} $name]

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
                        [subst [switch $argtype $argtypes]]
                    }]
                }
                if {$rtype == "void"} {
                    set saverv [subst {
                        $cname ([join $argnames ", "]);
                        return TCL_OK;
                    }]
                } else {
                    set saverv [subst {
                        $rtype rv = $cname ([join $argnames ", "]);
                        [subst [switch $rtype $rtypes]]
                    }]
                }

                variable procs
                dict set procs $name [subst {
                    static $rtype $cname ([join $arglist ", "]) {
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
                variable procs
                variable cflags

                set init [subst {
                    int Cfile_Init(Tcl_Interp* interp) {
                        [join [lmap name [dict keys $procs] {
                            set cname [string map {":" "_"} $name]
                            set tclname $name
                            if {[string first :: $tclname] != 0} {
                                set tclname [uplevel [list namespace current]]::$name
                            }
                            puts "Creating C command: $tclname"
                            subst {
                                Tcl_CreateObjCommand(interp, "$tclname", [set cname]_Cmd, NULL, NULL);
                            }
                        }] "\n"]
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
