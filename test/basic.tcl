proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}
proc count condition {
    llength [Statements::findMatches $condition]
}

Assert programOakland has program code {
    Claim Omar lives in "Oakland"
}
Assert when Omar lives in /place/ {
    Claim $place is a place where Omar lives
}
Assert programNewYork has program code {
    Claim Omar lives in "New York"
}
Step

assert {[count [list /someone/ claims /p/ is a place where Omar lives]] == 2}

Assert programNewJersey has program code {
    Claim Omar lives in "New Jersey"
}
Step

assert {[count [list /someone/ claims /p/ is a place where Omar lives]] == 3}
