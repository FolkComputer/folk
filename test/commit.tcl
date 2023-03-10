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

# Forces an unmatch.
proc ::Unmatch {{level 0}} {
    set unmatchId $::matchId
    for {set i 0} {$i < $level} {incr i} {
        # Get first parent of unmatchId (should be the When)
        set unmatchWhenId [lindex [dict get $Matches::matches $unmatchId parents] 0]
        set unmatchId [lindex [dict get $Statements::statements $unmatchWhenId parents] 0]
    }

    Evaluator::reactToMatchRemoval $unmatchId
    dict unset Matches::matches $unmatchId
}
proc ::Every {event args} {
    if {$event eq "time"} {
        set body [lindex $args end]
        set pattern [lreplace $args end end]
        uplevel [list When {*}$pattern $body]
    }
}

Assert programUpdate has program code {
    Commit { Claim there have been 0 boops }

    When there is a boop {
        When there have been /n/ boops {
            Commit { Claim there have been [expr {$n + 1}] boops }
            Unmatch 1
        }
    }
    Claim there is a boop
}
Step

assert {[dict get [lindex [Statements::findMatches [list /someone/ claims there have been /n/ boops]] 0] n] eq 1}
