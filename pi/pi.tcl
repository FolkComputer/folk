package require Thread
proc errorproc {id errorInfo} {puts "Thread error in $id: $errorInfo"}
thread::errorproc errorproc

try {
    set keyboardThread [thread::create [format {
        source "pi/Keyboard.tcl"
        source "pi/KeyCodes.tcl"
        source "lib/c.tcl"
        source "pi/cUtils.tcl"
        Keyboard::init
        puts "Keyboard tid: [getTid]"

        set keyStates [list up down repeat]
        set modifiers [dict create \
            shift 0 \
            ctrl 0 \
            alt 0 \
        ]

        while true {
            lassign [Keyboard::getKeyEvent] keyCode eventType

            set shift [dict get $modifiers shift]
            set key [keyFromCode $keyCode $shift]
            set keyState [lindex $keyStates $eventType]

            set isDown [expr {$keyState != "up"}]
            if {[string match *SHIFT $key]} {
              dict set modifiers shift $isDown
            }
            if {[string match *CTRL $key]} {
              dict set modifiers ctrl $isDown
            }
            if {[string match *ALT $key]} {
              dict set modifiers alt $isDown
            }

            set heldModifiers [dict keys [dict filter $modifiers value 1]]

            # Use `list` to escape special chars (brackets, quotes, whitespace)
            thread::send -async "%s" [subst {
                # puts "Keyboard thread: $key $keyState $heldModifiers"
                Retract keyboard claims key /k/ is /t/ with modifiers /m/
                Assert keyboard claims key [list $key] is [list $keyState] with modifiers [list $heldModifiers]
            }]
        }
    } [thread::id]]]
    puts "Keyboard thread id: $keyboardThread"
} on error error {
    puts stderr "Keyboard thread failed: $error"
}

loadVirtualPrograms
forever { Step }
