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
    set cc [uplevel {namespace current}]::$cc
    $cc code {
        typedef struct {
            uint32_t width;
            uint32_t height;
            int components;
            uint32_t bytesPerRow;

            uint8_t *data;
        } image_t;
    }

    $cc argtype image_t {
        image_t $argname; sscanf(Tcl_GetString($obj), "width %u height %u components %d bytesPerRow %u data 0x%p", &$argname.width, &$argname.height, &$argname.components, &$argname.bytesPerRow, &$argname.data);
    }
    $cc rtype image_t {
        $robj = Tcl_ObjPrintf("width %u height %u components %d bytesPerRow %u data 0x%" PRIxPTR, $rvalue.width, $rvalue.height, $rvalue.components, $rvalue.bytesPerRow, (uintptr_t) $rvalue.data);
    }
}

proc ::defineFolkImages {cc} {
    set cc [uplevel {namespace current}]::$cc
    $cc include <sys/mman.h>
    $cc include <sys/stat.h>
    $cc include <fcntl.h>
    $cc include <unistd.h>
    $cc include <stdlib.h>
    $cc code {
        uint8_t* folkImagesBase = (uint8_t*) 0x280000000;
        size_t folkImagesSize = 100000000; // 100MB
    }
    $cc proc folkImagesMount {} void {
        int fd = shm_open("/folk-images", O_RDWR | O_CREAT, S_IROTH | S_IWOTH | S_IRUSR | S_IWUSR);
        ftruncate(fd, folkImagesSize);
        void* ptr = mmap(folkImagesBase, folkImagesSize,
                         PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
        if (ptr == NULL || ptr != folkImagesBase) {
            fprintf(stderr, "shmMount: failed"); exit(1);
        }
    }
    $cc cflags -lrt
}
