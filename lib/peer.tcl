lappend auto_path "./vendor"

namespace eval clauseset {
    # only used for statement syndication

    namespace export create add remove minus clauses
    proc create {args} {
        set kvs [list]
        foreach k $args { lappend kvs $k true }
        dict create {*}$kvs
    }
    proc add {sv k} { upvar $sv s; dict set s $k true }
    proc remove {sv k} { upvar $sv s; dict unset s $k }
    proc minus {s t} {
        dict filter $s script {k v} {expr {![dict exists $t $k]}}
    }
    proc clauses {s} { dict keys $s }
    namespace ensemble create
}

namespace eval ::Peers {}

proc ::peer {process} {
    package require websocket
    namespace eval ::Peers::$process {
        variable connected false
        variable prevShareStatements [clauseset create]
        variable prevReceivedStatements [clauseset create]

        proc log {s} {
            variable process
            puts "$::thisProcess -> $process: $s"
        }
        proc setupSock {} {
            variable process
            log "Trying to connect to: ws://$process:4273/ws"
            variable sock [::websocket::open "ws://$process:4273/ws" [namespace code handleWs]]
        }
        proc handleWs {sock type msg} {
            if {$type eq "connect"} {
                log "Connected"
                variable connected true

                # Establish a peering on their end, in the reverse
                # direction, so they can send stuff back to us.
                # It'll implicitly run in a ::Peers::X namespace on their end
                # (because of how `run` is implemented above)
                run {
                    variable chan [uplevel {set chan}]
                    variable connected true
                    variable prevShareStatements [clauseset create]
                    variable prevReceivedStatements [clauseset create]
                    proc run {msg} {
                        variable chan
                        ::websocket::send $chan text $msg
                    }
                }
            } elseif {$type eq "disconnect"} {
                log "Disconnected"
                variable connected false
                variable prevShareStatements [clauseset create]
                variable prevReceivedStatements [clauseset create]
                after 2000 [namespace code setupSock]
            } elseif {$type eq "error"} {
                log "WebSocket error: $type $msg"
                after 2000 [namespace code setupSock]
            } elseif {$type eq "text"} {
                eval $msg
            } elseif {$type eq "ping" || $type eq "pong"} {
            } else {
                error "Unknown WebSocket event: $type $msg"
            }
        }

        proc run {msg} {
            variable sock
            ::websocket::send $sock text [list namespace eval ::Peers::$::thisProcess $msg]
        }

        proc init {n} {
            variable process $n; setupSock
            vwait ::Peers::${n}::connected
        }
        init
    } $process
}
