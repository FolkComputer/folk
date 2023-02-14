lappend auto_path "./vendor"
package require websocket

proc ::peer {node} {
    namespace eval Peers::$node {
        proc setupSock {} {
            variable node
            puts "peer: Trying to connect to: ws://$node:4273/ws"
            variable sock [::websocket::open "ws://$node:4273/ws" [namespace code handleWs]]
        }
        proc handleWs {sock type msg} {
            if {$type eq "connect"} {
                puts "peer: Connected"
            } elseif {$type eq "disconnect"} {
                puts "peer: Disconnected"
                after 2000 [namespace code setupSock]
            } elseif {$type eq "error"} {
                puts "peer: WebSocket error: $type $msg"
                after 2000 [namespace code setupSock]
            } elseif {$type eq "text" || $type eq "ping" || $type eq "pong"} {
                # We don't handle responses yet.
            } else {
                error "Unknown WebSocket event: $type $msg"
            }
        }

        proc run {msg} {
            variable sock
            ::websocket::send $sock text $msg
        }

        proc init {n} { variable node $n; setupSock }
        init
    } $node
}
