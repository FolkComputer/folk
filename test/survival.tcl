Assert when we are running {{} {
    When the collected matches for [list tag /k/ is visible] are /matches/ {
        foreach m $matches {
            Claim a tag is visible
        }
        puts "Collecting: [llength $matches] matches"
    }
    When a tag is visible {
        On unmatch {
            puts "Unmatching. Should not unmatch"
        }
    }
}}
Assert we are running
Step

Assert tag 1 is visible
Step

Assert tag 2 is visible
Assert tag 3 is visible
Retract tag 1 is visible
Step
