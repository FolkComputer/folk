package require Thread
proc errorproc {id errorInfo} {puts "Thread error in $id: $errorInfo"}
thread::errorproc errorproc

try {
    set keyboardThread [thread::create [format {
        source "pi/Keyboard.tcl"
        source "lib/c.tcl"
        source "pi/cUtils.tcl"
        Keyboard::init
        puts "Keyboard tid: [getTid]"

        set chs [list]
        while true {
            lappend chs [Keyboard::getChar]

            thread::send -async "%s" [subst {
                Retract keyboard claims the keyboard character log is /something/
                Assert keyboard claims the keyboard character log is "$chs"
            }]
        }
    } [thread::id]]]
    puts "Keyboard thread id: $keyboardThread"
} on error error {
    puts stderr "Keyboard thread failed: $error"
}

loadVirtualPrograms
forever { Step }
