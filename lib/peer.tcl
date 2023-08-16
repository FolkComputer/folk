lappend auto_path "./vendor"

namespace eval clauseset {
    # only used for statement syndication

    namespace export create add union difference clauses size
    proc create {args} {
        set kvs [list]
        foreach k $args { lappend kvs $k true }
        dict create {*}$kvs
    }
    proc add {sv stmt} { upvar $sv s; dict set s $stmt true }

    proc union {s t} { dict merge $s $t }
    proc difference {s t} {
        dict filter $s script {k v} {expr {![dict exists $t $k]}}
    }

    proc size {s} { dict size $s }
    proc clauses {s} { dict keys $s }
    namespace ensemble create
}

namespace eval ::Peers {}
set ::peersBlacklist [dict create]

proc ::peer {process {dieOnDisconnect false}} {
    namespace eval ::Peers::$process {
        variable connected true

        proc log {s} {
            variable process
            puts "$::thisProcess -> $process: $s"
        }

        # TODO: Handle die on disconnect (?)

        proc share {statements} {
            variable process
            Mailbox::share $::thisProcess $process $statements
        }
        proc receive {} {
            variable process
            Mailbox::receive $process $::thisProcess
        }

        proc init {n shouldDieOnDisconnect} {
            variable process $n
            variable dieOnDisconnect $shouldDieOnDisconnect

            Mailbox::create $::thisProcess $process
            Mailbox::create $process $::thisProcess
        }
        init
    } $process $dieOnDisconnect
}
