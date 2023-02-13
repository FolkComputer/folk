# temporarily disabled
return

proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}
proc count condition {
    llength [Statements::findMatches $condition]
}

Assert there is a cool thing
Assert there is a cool thing
Step

Retract there is a cool thing
Step

assert {[count [list there is a cool thing]] == 1}
