if {[info exists ::env(FOLK_SHARE_NODE)]} {
    set ::shareNode $::env(FOLK_SHARE_NODE)
} else {
    set wifi [exec sh -c {/Sy*/L*/Priv*/Apple8*/V*/C*/R*/airport -I | sed -n "s/^.*SSID: \(.*\)$/\1/p"}]
    if {$wifi eq "cynosure"} { set ::shareNode "folk-mott.local" } \
    else { set ::shareNode "folk0.local" }
}

lappend auto_path "./vendor"
package require websocket

proc handleWs {sock type msg} {
    if {$type eq "connect"} {
        puts stderr "sharer: Connected"
        repl
    } elseif {$type eq "disconnect"} {
        puts stderr "sharer: Disconnected"
        after 2000 { setupSock }
    } else {
        set ::response $msg
    }
}

proc setupSock {} {
    puts stderr "sharer: Trying to connect to: ws://$::shareNode:4273/ws"
    set ::sock [::websocket::open "ws://$::shareNode:4273/ws" handleWs]
}
setupSock

proc repl {} {
    set prompt "% "
    while 1 {
        puts -nonewline $prompt
        flush stdout
        gets stdin line        ;# read...
        if [eof stdin] break
        ::websocket::send $::sock text $line
        vwait ::response
        puts $::response
    }
}

vwait forever
