package require critcl

critcl::tcl 8.6
critcl::cflags -Wall -Werror

critcl::debug symbols
critcl::config keepsrc 1
critcl::ccode {
    #include <stdint.h>
    #include <inttypes.h>
    typedef uint32_t pixel_t;
    typedef struct {
        unsigned width;
        unsigned height;
        pixel_t* pixels;
    } drawable_surface_t;
    
}
critcl::argtype drawable_surface_t {
    sscanf(Tcl_GetString(@@), "%d %d 0x%p", &@A.width, &@A.height, &@A.pixels);
} drawable_surface_t
critcl::resulttype drawable_surface_t {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%d %d 0x%" PRIxPTR, rv.width, rv.height, (uintptr_t) rv.pixels));
    return TCL_OK;
} drawable_surface_t
critcl::cproc newDrawableSurface {int width int height} drawable_surface_t {
    printf("new drawable surface::::--\n");

    drawable_surface_t ret;
    ret.pixels = (pixel_t *) Tcl_Alloc(width * height * sizeof(pixel_t));
    ret.width = width; ret.height = height;
    return ret;
}

puts Hello.
puts [newDrawableSurface 1000 1000]
