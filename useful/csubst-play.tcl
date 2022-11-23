proc csubst {s} {
    # much like subst, but you invoke a Tcl fn with $[whatever]
    # instead of [whatever]
    set result [list]
    for {set i 0} {$i < [string length $s]} {incr i} {
        set c [string index $s $i]
        switch $c {
            {$} {
                set tail [string range $s $i+1 end]
                if {[regexp {^[A-Za-z0-9:()_]+} $tail varname]} {
                    lappend result [uplevel [list set $varname]]
                    incr i [string length $varname]
                } elseif {[string index $tail 0] eq "\["} {
                    set bracketcount 0
                    for {set j 0} {$j < [string length $tail]} {incr j} {
                        set ch [string index $tail $j]
                        if {$ch eq "\["} { incr bracketcount } \
                        elseif {$ch eq "]"} { incr bracketcount -1 }
                        if {$bracketcount == 0} { break }
                    }
                    puts [string range $tail 0 $j]
                    lappend result [uplevel [string range $tail 1 $j-1]]
                }
            }
            default {lappend result $c}
        }
    }
    join $result ""
}

set world "Earth"
puts [csubst {
    printf("hello $world\n");
    printf("hello $::env(HOME)\n");
    $[puts hey]
    $[puts [expr {2 + 2}]]
}]
