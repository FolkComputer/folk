set wifi "Fios-LGTS3-5G"
catch {
    if {$::tcl_platform(os) eq "Darwin"} {
        set wifi [exec sh -c {/Sy*/L*/Priv*/Apple8*/V*/C*/R*/airport -I | sed -n "s/^.*SSID: \(.*\)$/\1/p"}]
    } elseif {$::tcl_platform(os) eq "Linux"} {
        set wifi [exec iwgetid -r]
    }
}

if {$wifi eq "cynosure"} { set ::shareNode "folk-omar.local" } \
elseif {$wifi eq "Verizon_TWRHB4"} { set ::shareNode "folk-cwervo.local" } \
elseif {$wifi eq "Fios-LGTS3-5G" || $wifi eq "Fios-LGTS3"} { set ::shareNode "folk0.local" } \
else { set ::shareNode "folk0.local" }

if {[info exists ::env(FOLK_SHARE_NODE)]} {
    set ::shareNode $::env(FOLK_SHARE_NODE)
}
if {$::shareNode eq "none"} { unset ::shareNode }

if {[info exists ::argv] && $::argv eq "shareNode"} {
    puts $::shareNode
}
