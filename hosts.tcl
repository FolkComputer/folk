if {$::tcl_platform(os) eq "Darwin"} {
    set wifi [exec sh -c {/Sy*/L*/Priv*/Apple8*/V*/C*/R*/airport -I | sed -n "s/^.*SSID: \(.*\)$/\1/p"}]
} elseif {$::tcl_platform(os) eq "Linux"} {
    set wifi [exec iwgetid -r]
}

if {$wifi eq "cynosure"} { set ::shareNode "folk-omar.local" } \
else { set ::shareNode "folk0.local" }

if {[info exists ::argv] && $::argv eq "shareNode"} {
    puts $::shareNode
}
