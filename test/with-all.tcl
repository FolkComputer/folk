proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

Assert programOakland has program code {
    Claim Omar lives in "Oakland"
}
Assert program3 has program code {
    When the collected matches for [list Omar lives in /place/] are /matches/ {
        Claim there are [llength $matches] matches
    }
}
Assert programNewYork has program code {
    Claim Omar lives in "New York"
}
Step

assert {[llength [Statements::findMatches [list /someone/ claims there are 2 matches]]] == 1}

Retract programOakland has program code /something/
Step

assert {[llength [Statements::findMatches [list /someone/ claims there are /n/ matches]]] == 1}
assert {[llength [Statements::findMatches [list /someone/ claims there are 1 matches]]] == 1}

Retract programNewYork has program code /something/
Assert programNewYork has program code {
    Claim Omar lives in "New York"
}
# exec dot -Tpdf >preassert.pdf <<[Statements::dot]
Step
# exec dot -Tpdf >postassert.pdf <<[Statements::dot]

assert {[llength [Statements::findMatches [list /someone/ claims there are /n/ matches]]] == 1}
assert {[llength [Statements::findMatches [list /someone/ claims there are 1 matches]]] == 1}

Retract programNewYork has program code /something/
Step
assert {[llength [Statements::findMatches [list /someone/ claims there are /n/ matches]]] == 1}
assert {[llength [Statements::findMatches [list /someone/ claims there are 1 matches]]] == 0}
assert {[llength [Statements::findMatches [list /someone/ claims there are 0 matches]]] == 1}

Retract /x/ has program code /y/
Step

Assert labeller has program code {
    When labelling is on /k/ {
        When the collected matches for [list /someone/ wishes /p/ is labelled /label/] are /matches/ {
            Claim the total label on $k is [lmap m $matches {dict get $m label}]
        }
    }
}
Assert programWithLabels has program code {
    Wish $this is labelled "Label One"
    Wish $this is labelled "Label Two"
}
Assert labelling is on A
Step
exec dot -Tpdf >A.pdf <<[Statements::dot]

Retract labelling is on A
Step
exec dot -Tpdf >Ax.pdf <<[Statements::dot]

Assert labelling is on B
Step
exec dot -Tpdf >AxB.pdf <<[Statements::dot]

assert {[llength [Statements::findMatches [list /someone/ claims the total label on /k/ is /l/]]] == 1}

When the collected matches for [list unmatched statement] are /matches/ {
    set ::unmatchedStatementMatches $matches
}
Step
assert {[llength $::unmatchedStatementMatches] == 0}

Assert Omar claims blah has number 3
Assert Omar claims blah has text "three"
When the collected matches for [list /x/ has number /n/ & /x/ has text /text/] are /matches/ {
    set match [lindex $matches 0]
    dict with match {
        set ::collectedjoin [list $x has number $n & $x has text $text]
    }
}
Step
assert {$::collectedjoin eq "blah has number 3 & blah has text three"}
