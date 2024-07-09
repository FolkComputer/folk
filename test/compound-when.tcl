proc count condition {
    Statements::count $condition
}

proc printWithNested {text} {
    puts "$text \[nested\]"
}


proc printWithCompound {text} {
    puts "$text \[compound\]"
}

Assert programCompound has program {{this} {
    set ::NestedResult ""
    When /note/ is a post-it {
        When the collected matches for [list /note/ has /topic/ with weight /weight/] are /matches/ {
            append ::NestedResult "Note binding: $note\n"
            foreach match $matches {
                set matchNote [dict get $match note]
                printWithNested "looking at $matchNote + $note ([expr {$note eq $matchNote}])"
                dict with match {
                    # This is NOT equivalnet to the puts two lines above because $note here is now bound to the match
                    printWithNested "----- looking at $matchNote + $note ([expr {$note eq $matchNote}])"
                    if {$note eq $matchNote} {
                        printWithNested "equivalent"
                        append ::NestedResult "Match: topic=$topic, weight=$weight\n"
                    } else {
                        printWithNested "!!!! not eq"
                    }
                }
            }
        }
    }
    
    When /note/ is a post-it &\
        the collected matches for [list /note/ has /topic/ with weight /weight/] are /matches/ {
        append ::CompoundResult "Note binding: $note\n"
            foreach match $matches {
                set matchNote [dict get $match note]
                printWithCompound "looking at $matchNote + $note"
                dict with match {
                    if {$note eq $matchNote} {
                        append ::CompoundResult "Match: topic=$topic, weight=$weight\n"
                    } else {
                        printWithCompound "!!!!! not eq"
                    }
                }
            }
    }
}}

Assert thing1 is a post-it
Assert thing2 is a post-it
Assert thing1 has programming with weight 1
Assert thing2 has writing with weight 0.9
Step

# puts "Result:\n$::CompoundResult"

# set expected_result "Note binding: thing1\n\
# Match: topic=programming, weight=1\n\
# Note binding: thing2\n\
# Match: topic=writing, weight=0.9\n"

set expected [list \
    "Note binding: thing1\n" \
    "Match: topic=programming, weight=1\n" \
    "Note binding: thing2\n" \
    "Match: topic=writing, weight=0.9\n" \
]
set expected_result [join $expected ""]

# puts "Nested result:\n$::NestedResult"
# puts "expected:\n$::expected_result"

# set expected_NestedResult [join $::expected_NestedResult]
# puts "Expected nested result:\n$::expected_NestedResult"

puts "test nesting and compound are equivalent:"
assert {$::NestedResult eq $::CompoundResult}

# assert {$::NestedResult eq $expected}
# assert {$::CompoundResult eq $expected_result}

assert {[count {/note/ is a post-it}] == 2}
assert {[count {/note/ has /topic/ with weight /weight/}] == 2}

set ::CompoundResult ""
Step
assert {$::CompoundResult eq ""}