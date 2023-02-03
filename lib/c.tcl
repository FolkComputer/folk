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

            ::proc cstyle {type name} {
                if {[regexp {([^\[]+)(\[\d*\])$} $type -> basetype arraysuffix]} {
                    return [list $basetype $name$arraysuffix]
                }
                list $type $name
            }
            ::proc typestyle {type name} {
                if {[regexp {([^\[]+)(\[\d*\])$} $name -> basename arraysuffix]} {
                    return [list $type$arraysuffix $basename]
                }
                list $type $name
            }

            variable argtypes {
                int { expr {{ Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                size_t { expr {{ Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                uint32_t { expr {{ sscanf(Tcl_GetString($obj), "%"PRIu32, &$argname); }}}
                uint64_t { expr {{ sscanf(Tcl_GetString($obj), "%"PRIu64, &$argname); }}}
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
                        # note: arraylen can be ""
                        expr {{
                            {
                                int objc; Tcl_Obj** objv;
                                Tcl_ListObjGetElements(interp, $obj, &objc, &objv);
                                for (int i = 0; i < $arraylen; i++) {
                                    $[arg $basetype $argname\[i\] objv\[i\]]
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
            ::proc code {newcode} { variable code; lappend code $newcode; list }

            ::proc parseStruct {body} {
                set lines [split $body "\n"]
                set lines [lmap line [split $body "\n"] {

                }]
                set fields [dict create]
                foreach line $lines {
                    puts "line {$line}"
                    set fieldtype [lindex $line 0]
                    set fieldname [regexp -inline -- {(.*?)//.*$} [lindex $line end]]
                    dict set fields $fieldtype $fieldname
                }
                set fields
            }
            ::proc struct {type fields} {
                regsub -all -line {/\*.*?\*/} $fields "" fields
                regsub -all -line {//.*$} $fields "" fields

                variable code
                lappend code [subst {
                    typedef struct $type $type;
                    struct $type {$fields};
                }]

                variable argtypes
                set argscripts [list] ;# TODO: return a dictionary
                dict for {fieldtype fieldname} $fields {
                    set fieldname [string map {";" ""} $fieldname]
                    lassign [typestyle $fieldtype $fieldname] fieldtype fieldname
                    lappend argscripts [csubst {
                        Tcl_Obj* obj_$fieldname;
                        Tcl_DictObjGet(interp, \$obj, Tcl_ObjPrintf("%s", "$fieldname"), &obj_$fieldname);
                    }]
                    lappend argscripts [arg $fieldtype \$argname.$fieldname obj_$fieldname]
                }
                set argtypes [linsert $argtypes 0 $type [list expr [list [join $argscripts "\n"]]]]

                variable rtypes
                set rscripts [list { $robj = Tcl_NewDictObj(); }]
                dict for {fieldtype fieldname} $fields {
                    set fieldname [string map {";" ""} $fieldname]
                    lassign [typestyle $fieldtype $fieldname] fieldtype fieldname
                    lappend rscripts [csubst {Tcl_Obj* robj_$fieldname;}]
                    lappend rscripts [ret $fieldtype robj_$fieldname \$rvalue.$fieldname]
                    lappend rscripts [csubst {
                        Tcl_DictObjPut(interp, \$robj, Tcl_ObjPrintf("%s", "$fieldname"), robj_$fieldname);
                    }]
                }
                set rtypes [linsert $rtypes 0 $type [list expr [list [join $rscripts "\n"]]]]
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
                    lappend arglist [join [cstyle $argtype $argname] " "]
                    lappend argnames $argname

                    if {$argtype == "Tcl_Interp*" && $argname == "interp"} { continue }

                    set obj [subst {objv\[1 + [llength $loadargs]\]}]
                    lappend loadargs [subst {
                        [join [cstyle $argtype $argname] " "];
                        [arg $argtype $argname $obj]
                    }]
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

                set uniquename [string map {":" "_"} [uplevel [list namespace current]]]__$name
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
                            # puts "Creating C command: $tclname"
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
