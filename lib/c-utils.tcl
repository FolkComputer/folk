if {[namespace exists c] && $::tcl_platform(os) eq "Linux"} {
    set handle [c create]
    $handle include <sys/syscall.h>
    $handle include <unistd.h>
    $handle proc getTid {} int {
        return syscall(SYS_gettid);
    }
    $handle compile
}

# FIXME: this shouldn't be global
proc ::defineImageType {cc} {
    uplevel [list $cc struct image_t {
        uint32_t width;
        uint32_t height;
        int components;
        uint32_t bytesPerRow;

        uint8_t* data;
    }]
}
