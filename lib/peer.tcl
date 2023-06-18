lappend auto_path "./vendor"

namespace eval clauseset {
    # only used for statement syndication

    namespace export create add minus clauses
    proc create {args} {
        set kvs [list]
        foreach k $args { lappend kvs $k true }
        dict create {*}$kvs
    }
    proc add {sv k} { upvar $sv s; dict set s $k true }
    proc minus {s t} {
        dict filter $s script {k v} {expr {![dict exists $t $k]}}
    }
    proc clauses {s} { dict keys $s }
    namespace ensemble create
}

namespace eval ::Peers {}

proc ::peer {node} {
    package require websocket
    namespace eval ::Peers::$node {
        variable connected false
        variable prevShareStatements [clauseset create]

        proc log {s} {
            variable node
            puts "$::thisProcess -> $node: $s"
        }
        proc setupSock {} {
            variable node
            log "Trying to connect to: ws://$node:4273/ws"
            variable sock [::websocket::open "ws://$node:4273/ws" [namespace code handleWs]]
        }
        proc handleWs {sock type msg} {
            if {$type eq "connect"} {
                log "Connected"
                variable connected true
            } elseif {$type eq "disconnect"} {
                log "Disconnected"
                variable connected false
                variable prevShareStatements [clauseset create]
                after 2000 [namespace code setupSock]
            } elseif {$type eq "error"} {
                log "WebSocket error: $type $msg"
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

        proc init {n} {
            variable node $n; setupSock
            vwait ::Peers::${n}::connected

            # Establish a peering on their end, in the reverse
            # direction, so they can send stuff back to us.
            run [format {
                namespace eval {::Peers::%s} {
                    variable connected true
                    variable prevShareStatements [clauseset create]
                    proc run {msg} {
                        variable chan
                        ::websocket::send $chan text $msg
                    }

                    variable chan
                } $chan
            } $::thisProcess]
        }
        init
    } $node
}
