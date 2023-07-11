source "hosts.tcl"

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
        ::websocket::send $::sock text [list apply {{line} {
            upvar chan chan
            ::websocket::send $chan text [eval $line]
        }} $line]
        vwait ::response
        puts $::response
    }
}

vwait forever
