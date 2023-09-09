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

proc ::addMatchesToShareStatements {shareStatementsVar matches} {
    upvar $shareStatementsVar shareStatements
    foreach m $matches {
        set pattern [dict get $m pattern]
        foreach match [Statements::findMatches $pattern] {
            set id [lindex [dict get $match __matcheeIds] 0]
            set clause [statement clause [Statements::get $id]]
            clauseset add shareStatements $clause
        }
    }
}

proc ::peer {process {dieOnDisconnect false}} {
    namespace eval ::Peers::$process {
        variable connected true

        proc log {s} {
            variable process
            puts "$::thisProcess -> $process: $s"
        }

        # TODO: Handle die on disconnect (?)

        proc send {statements} {
            variable process
            Mailbox::share $::thisProcess $process $statements
        }
        proc receive {} {
            variable process
            Mailbox::receive $process $::thisProcess
        }

        proc share {shareStatements} {
            variable process
            variable prevShareStatements

            variable connected
            if {!$connected} { return }

            # Share.
            ::addMatchesToShareStatements shareStatements \
                [Statements::findMatches [list /someone/ wishes $process receives statements like /pattern/]]
            if {![info exists prevShareStatements] ||
                ([clauseset size $prevShareStatements] > 0 ||
                 [clauseset size $shareStatements] > 0)} {

                send [clauseset clauses $shareStatements]

                set prevShareStatements $shareStatements
            }
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
