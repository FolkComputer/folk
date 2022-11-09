if {![info exists ::livecprocs]} {set ::livecprocs [dict create]}
proc livecproc {name args} {
    if {[dict exists $::livecprocs $name $args]} {
        # promote this already-compiled proc
        dict set ::livecprocs $name [dict create $args [dict get $::livecprocs $name $args]]
    } else { ;# compile
        critcl::cproc $name$::stepCount {*}$args
        dict set ::livecprocs $name $args $name$::stepCount
    }
    proc $name {args} {
        set name [lindex [info level 0] 0]
        [lindex [dict values [dict get $::livecprocs $name]] end] {*}$args
    }
}

namespace eval c {
    ::proc proc {name args rtype body} {
        
    }
}
