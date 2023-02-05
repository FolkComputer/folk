proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

set fd [open "virtual-programs/with-all.folk" r]
Assert program1 has program code [read $fd]
close $fd

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

proc countCollectedMatches {clause} {
    set collections [Statements::findMatches [list the collected matches for $clause are /matches/]]
    assert {[llength $collections] == 1}
    llength [dict get [lindex $collections 0] matches]
}
assert {[countCollectedMatches [list Omar lives in /place/]] == 2}
assert {[llength [Statements::findMatches [list /someone/ claims there are 2 matches]]] == 1}

exec dot -Tpdf >preretract.pdf <<[Statements::dot]
Retract programOakland has program code /something/
Step
exec dot -Tpdf >postretract.pdf <<[Statements::dot]

assert {[countCollectedMatches [list Omar lives in /place/]] == 1}
assert {[llength [Statements::findMatches [list /someone/ claims there are 1 matches]]] == 1}

Retract programNewYork has program code /something/
Assert programNewYork has program code {
    Claim Omar lives in "New York"
}
Step

assert {[countCollectedMatches [list Omar lives in /place/]] == 1}
assert {[llength [Statements::findMatches [list /someone/ claims there are 1 matches]]] == 1}
