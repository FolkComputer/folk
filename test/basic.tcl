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
Assert when $::nodename has step count /c/ {
    When Omar lives in /place/ {
        Claim $place is a place where Omar lives
    }
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

set ::outlinecolors [dict create]
Assert someone wishes BlueThing is outlined blue
Assert someone claims BlueThing has region BlueThingRegion
Assert when /someone/ wishes /thing/ is outlined /color/ {
    When $thing has region /r/ {
        dict set ::outlinecolors $thing $color
    }
}
Assert someone wishes GreenThing is outlined green
Assert someone claims GreenThing has region GreenThingRegion
Step

assert {$::outlinecolors eq "BlueThing blue GreenThing green"}

Assert someone claims BlueThing has region BlueThingRegion2
Retract someone claims BlueThing has region BlueThingRegion
Step

assert {$::outlinecolors eq "BlueThing blue GreenThing green"}
