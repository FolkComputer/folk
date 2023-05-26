proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}


Assert we are running
Assert when we are running {
    On process {
        set cc [c create]
        $cc include <sys/mman.h>
        $cc include <sys/stat.h>
        $cc include <fcntl.h>
        $cc include <unistd.h>
        $cc include <stdlib.h>
        $cc proc shmMount {char* name size_t size void* addr} void {
            int fd = shm_open(name, O_RDWR | O_CREAT, S_IROTH | S_IWOTH | S_IRUSR | S_IWUSR);
            ftruncate(fd, size);
            void* ptr = mmap(addr, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
            if (ptr == NULL || ptr != addr) {
                fprintf(stderr, "shmMount: failed"); exit(1);
            }
        }
        $cc proc blup {} void {
            void* ptr = (void*)0x280000000;
            shmMount("/folk-images", 1000000000, ptr);

            char* s = (char*)ptr;
            snprintf(s, 100, "Hello!");
        }
        $cc compile
        blup
    }

    On process {
        set cc [c create]
        $cc include <sys/mman.h>
        $cc include <sys/stat.h>
        $cc include <fcntl.h>
        $cc include <unistd.h>
        $cc include <stdlib.h>
        $cc proc shmMount {char* name size_t size void* addr} void {
            int fd = shm_open(name, O_RDWR | O_CREAT, S_IROTH | S_IWOTH | S_IRUSR | S_IWUSR);
            ftruncate(fd, size);
            void* ptr = mmap(addr, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
            if (ptr == NULL || ptr != addr) {
                fprintf(stderr, "shmMount: failed"); exit(1);
            }
        }
        $cc proc blup {} void {
            void* ptr = (void*)0x280000000;
            shmMount("/folk-images", 1000000000, ptr);

            char* s = (char*)ptr;
            printf("[%s]\n", s);
        }
        $cc compile
        blup
    }
}
Step

after 1000 {set done true}
vwait done
