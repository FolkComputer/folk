Assert programNegation has program code {
    When /nobody/ is booping {
        set ::booping nope
        On unmatch {
            set ::booping nowpeopleare
        }
    }
}
Step
assert {$::booping eq "nope"}

Assert guy is booping
Step
assert {$::booping eq "nowpeopleare"}
