proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

Assert Omar is a person
Assert Omar lives in "New York"
Step

Assert when /x/ is a person & /x/ lives in /place/ {
    set ::foundX $x
}
Step

assert {$::foundX eq "Omar"}
