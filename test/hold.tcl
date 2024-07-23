Assert programBall has program {{this} {
    Hold { Claim $this has a ball at x 100 y 100 }

    When $this has a ball at x /x/ y /y/ {
        After 10 milliseconds {
            Hold { Claim $this has a ball at x $x y [expr {$y+1}] }
            if {$y > 115} { set ::done true }
        }
    }
}}
Step

vwait ::done

Retract programBall has program /something/

Assert programUpdate has program {{this} {
    Hold { Claim $this has seen 0 boops }

    Every time there is a boop & $this has seen /n/ boops {
        Hold { Claim $this has seen [expr {$n + 1}] boops }
    }
}}
Assert there is a boop
Step

assert {[dict get [lindex [Statements::findMatches [list /someone/ claims /thing/ has seen /n/ boops]] 0] n] eq 1}

Retract there is a boop
Assert there is a boop
Step

assert {[dict get [lindex [Statements::findMatches [list /someone/ claims /thing/ has seen /n/ boops]] 0] n] eq 2}

#################

Assert programTestReset has program {{this} {
    When $this has context color /color/ {
        Hold { Claim $this has counter 0 }
        Every time a button is pressed & $this has counter /counter/ {
            Hold { Claim $this has counter [incr counter] }
        }
    }
}}
Assert programTestReset has context color red
Assert a button is pressed
Step
Retract a button is pressed
Assert a button is pressed
Step
Retract a button is pressed
Assert a button is pressed
Step
proc getCounter {} {
    set results [Statements::findMatches [list /someone/ claims programTestReset has counter /counter/]]
    set firstResult [lindex $results 0]
    dict get $firstResult counter
}
assert {[getCounter] == 3}

Retract programTestReset has context color red
Assert programTestReset has context color blue
Step
assert {[getCounter] == 1}
