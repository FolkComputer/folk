proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

Assert programBall has program code {
    Commit { Claim there is a ball at x 100 y 100 }

    When there is a ball at x /x/ y /y/ {
        puts "ball at $x $y"
        After 10 milliseconds {
            Commit { Claim there is a ball at x $x y [expr {$y+1}] }
            if {$y > 115} { set ::done true }
        }
    }
}
Step

vwait ::done
Retract programBall has program code /something/

Assert programUpdate has program code {
    Commit { Claim there have been 0 boops }

    Every time there is a boop & there have been /n/ boops {
        Commit { Claim there have been [expr {$n + 1}] boops }
    }
}
Assert there is a boop
Step

assert {[dict get [lindex [Statements::findMatches [list /someone/ claims there have been /n/ boops]] 0] n] eq 1}

Retract there is a boop
Assert there is a boop
Step

assert {[dict get [lindex [Statements::findMatches [list /someone/ claims there have been /n/ boops]] 0] n] eq 2}

