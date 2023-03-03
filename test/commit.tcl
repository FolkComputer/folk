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
