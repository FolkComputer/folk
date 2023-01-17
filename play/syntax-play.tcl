proc Store {varName} {
    
}
proc Set {varName _ val} {
    
}

Store old images (initially [list])

Wish $this is labelled $x

When $::nodename has step count /c/ {
    Set x to $c
}

When $this has region /r/ {
    Wish $r has camera image
    When $r has camera image /i/ {
        Set old images to [lappend [Get old images] $i]
    }
}

On the display thread {
    source pi/Display.tcl
    Display::init
    puts "Display tid: [getTid]"
}

On the camera thread {

}

On unmatch {

}

Wish to collect matches for [list /someone/ wishes display runs /command/]
When the collected matches for [list /someone/ wishes display runs /command/] are /matches/ {
    set displayList [list]
    foreach match $matches { lappend displayList [dict get $match command] }

    On the display thread (capturing /displayList}) {
        proc lcomp {a b} {expr {[lindex $a 0] == "Display::text"}}

        # Draw the display list
        set displayList [lsort -command lcomp $displayList]
        lappend displayList {commitThenClearStaging}
        set displayTime [join $displayList "\n"]

        Claim the display time is $displayTime
    }
}

