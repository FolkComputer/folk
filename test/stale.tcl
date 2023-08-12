Assert when we are running {{} {
    When the iteration count is /k/ {
        Commit { Claim the counted iteration count is $k }
    }
}}
Assert we are running
Step

for {set i 0} {$i < 10000} {incr i} {
    Commit [list Claim the iteration count is $i]
    Step
}

exec dot -Tpdf >stale.pdf <<[Statements::dot]
