Assert Omar is a person
Assert Omar lives in "New York"
Assert Elmo is a person
Assert Elmo lives in "Sesame Street"
Step

assert {[dict get [lindex \
                       [Statements::findMatchesJoining \
                            [list {/p/ is a person} {/p/ lives in /place/}] \
                            {p "Elmo"}] \
                       0] place] eq "Sesame Street"}

set places [lmap m [Statements::findMatchesJoining \
                        [list {/p/ is a person} {/p/ lives in /place/}] \
                        {}] \
                {dict get $m place}]
assert {$places eq {{New York} {Sesame Street}}}

Assert p has program {{this} {
    When /x/ is a person & /x/ lives in /place/ {
        set ::found$x $place
    }
}}
Assert Ash is a person
Assert Ash lives in "Pallet Town"
Step

assert {
    $::foundOmar eq "New York" &&
    $::foundElmo eq "Sesame Street" &&
    $::foundAsh eq "Pallet Town"
}
