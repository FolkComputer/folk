# can i just like
# run some arbitrary C code

package require critcl

for {set i 0} {$i < 50} {incr i} {
    puts [time {
        puts [llength [namespace which prn]]
        critcl::cproc prn {} void {
            printf("hello %s\n", __BASE_FILE__);
        }
        puts [namespace which prn]
        prn
    }]
}
