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
                $prologue
                Tcl_SetObjResult(interp, Tcl_NewIntObj($name ($arg)));
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

c struct drawable_surface_t {
    
}
c proc newDrawableSurface {int width int height} drawable_surface_t {
    drawable_surface_t ret;
    ret.pixels = (pixel_t *) Tcl_Alloc(width * height * sizeof(pixel_t));
    ret.width = width; ret.height = height;
    return ret;
}
