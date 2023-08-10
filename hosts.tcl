# TODO: Find a good C sha-smth instead of this. 
proc hashString {str} {
  set hash 0
  foreach char [split $str ""] {
    set ascii [scan $char %c]
    set hash [expr {($hash * 31 + $ascii) & 0xffffffff}]
  }
  set hash
}

if {[info exists ::env(FOLK_SHARE_NODE)]} {
    set ::shareNode $::env(FOLK_SHARE_NODE)
} else {
    try {
        if {$::tcl_platform(os) eq "Darwin"} {
            set wifi [exec sh -c {/Sy*/L*/Priv*/Apple8*/V*/C*/R*/airport -I | sed -n "s/^.*SSID: \(.*\)$/\1/p"}]
        } elseif {$::tcl_platform(os) eq "Linux"} {
            set wifi [exec iwgetid -r]
        }

        if {$wifi eq "cynosure"} {
            set ::shareNode "folk-omar.local"
        } elseif {$wifi eq "Verizon_TWRHB4"} {
            set ::shareNode "folk-cwervo.local"
        } elseif {$wifi eq "WONDERLAND"} {
            set ::shareNode "folk-haip.local"
        } elseif {$wifi eq "GETNEAR"} {
            set ::shareNode "folk-ian.local"
        } elseif {$wifi eq "Fios-LGTS3-5G" || $wifi eq "Fios-LGTS3"} {
            set ::shareNode "folk0.local"
        } elseif {[string match "_onefact.org*" $wifi]} {
            set ::shareNode "folk-onefact.local"
        } elseif {[hashString $wifi] eq 4077950650 || [hashString $wifi] eq 862457117} {
            set ::shareNode "folk-arc.local"
        } elseif {$wifi eq "The Windfish"} {
            set ::shareNode "folk-dpip.local"
        } elseif {$wifi eq "interact residency"} {
            set ::shareNode "folk-interact.local"
        } else {
            # there's no default.
        }
    } on error e {
        set ::shareNode "none"
    }
}

if {[info exists ::shareNode] && $::shareNode eq "none"} { unset ::shareNode }

if {[info exists ::argv] && $::argv eq "shareNode"} {
    if {[info exists ::shareNode]} { puts $::shareNode } \
        else { puts none }
}
