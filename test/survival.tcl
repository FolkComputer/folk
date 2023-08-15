Assert when we are running {{} {
    When the collected matches for [list tag /k/ was seen by /x/ at /p/] are /matches/ {
        set tagsSeen [dict create]
        foreach m $matches {
            dict set tagsSeen [dict get $m k] true
        }
        dict for {k _} $tagsSeen { Claim tag $k is a tag }
    }
    When tag /k/ is a tag {
        puts "Saw tag $k"
        On unmatch { error "Should never unmatch" }
    }
}}
Assert we are running
Step

Commit Omar { Claim tag 1 was seen by Omar at home }
Commit Mom { Claim tag 1 was seen by Mom at restaurant }
Step

Commit Omar { Claim tag 1 was seen by Omar at work }
Step

# Statements::print

