for {set i 0} {$i < 30000} {incr i} {
    Commit [list Claim the iteration count is $i]
    Step
}

exec dot -Tpdf >stale.pdf <<[Statements::dot]
