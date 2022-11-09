namespace eval c {
    ::proc "proc" {name args rtype body} {
        puts "$name $args $rtype $body"
        set arglist [list]
        for {set i 0} {$i < [llength $args]} {incr i 2} {
            lappend arglist "[lindex $args $i] [lindex $args [expr {$i+1}]]"
        }
        set code [subst {
            #include <tcl.h>
            static $rtype $name ([join $arglist ", "]) {
                $body
            }

            static int [set name]_Cmd(ClientData cdata, Tcl_Interp* interp, int objc, Tcl_Obj* const objv\[]) {
                int a; int b;
                Tcl_GetIntFromObj(interp, objv\[1], &a);
                Tcl_GetIntFromObj(interp, objv\[2], &b);
                Tcl_SetObjResult(interp, Tcl_NewIntObj($name (a, b)));
                return TCL_OK;
            }

            int DLLEXPORT [string totitle $name]_Init(Tcl_Interp* interp) {
                Tcl_CreateObjCommand(interp, "$name", [set name]_Cmd, NULL, NULL);
                return TCL_OK;
            }
        }]
        puts $code

        set cfd [file tempfile cfile $name.c]; puts $cfd $code; close $cfd
        puts $cfile
        exec cc -shared -L$::tcl_library/.. -ltcl8.6 $cfile -o [file rootname $cfile].dylib
        load [file rootname $cfile].dylib $name
    }
    namespace export *
    namespace ensemble create
}

c proc add {int x int y} int {
    return x + y;
}
puts [add 2 3]
