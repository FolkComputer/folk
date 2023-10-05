lappend auto_path "./vendor"

namespace eval ::Peers {}
set ::peersBlacklist [dict create]

proc ::addMatchesToShareStatements {shareStatementsVar matches} {
    upvar $shareStatementsVar shareStatements
    foreach m $matches {
        set pattern [dict get $m pattern]
        foreach match [Statements::findMatches $pattern] {
            set id [lindex [dict get $match __matcheeIds] 0]
            set clause [statement clause [Statements::get $id]]
            dictset add shareStatements $clause
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
                ([dictset size $prevShareStatements] > 0 ||
                 [dictset size $shareStatements] > 0)} {

                send [dictset entries $shareStatements]

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
