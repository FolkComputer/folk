proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

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

# Assert when /x/ is a person & /x/ lives in /place/ {
#     set ::foundX $x
# }
# Step

# assert {$::foundX eq "Omar"}
