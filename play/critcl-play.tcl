# can i just like
# run some arbitrary C code

package require critcl

for {set i 0} {$i < 50} {incr i} {
    puts [time {
        if {[llength [namespace which prn]] < 1} {
            critcl::cproc prn {} void {
                printf("hello %s\n", __BASE_FILE__);
            }
        }
        prn
    }]
}
