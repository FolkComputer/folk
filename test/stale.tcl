for {set i 0} {$i < 30000} {incr i} {
    Hold [list Claim the iteration count is $i]
    Step
}

assert {[llength [Statements::findMatches [list /someone/ claims the iteration count is /i/]]] == 1}
