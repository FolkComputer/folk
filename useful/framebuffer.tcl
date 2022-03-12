set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

set red [binary format c4 {0 0 255 0}]
for {set i 0} {$i < 100} {incr i} {
    puts $fb $red
}
