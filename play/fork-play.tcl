source "lib/c.tcl"
set cc [c create]
$cc include <unistd.h>
$cc proc ::fork {} int {
    return fork();
}
$cc compile

puts "In parent ([pid]). Forking"
set pid [fork]
if {$pid == 0} {
    puts "In child ([pid]). Forking"
    set pid2 [fork]
    if {$pid2 == 0} {
        puts "In grandchild ([pid]). Done"
        exit 0
    }
    puts "In child. Done"
    exit 0
}

puts "In parent. Done"
while true {}
