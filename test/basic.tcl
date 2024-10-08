proc count condition {
    Statements::count $condition
}

Assert programOakland has program {{this} {
    Claim Omar lives in "Oakland"
}}
Assert when $::thisProcess has step count /c/ {{c} {
    When Omar lives in /place/ {
        Claim $place is a place where Omar lives
    }
}}
Assert programNewYork has program {{this} {
    Claim Omar lives in "New York"
}}
Step

assert {[count [list /someone/ claims /p/ is a place where Omar lives]] == 2}

Assert programNewJersey has program {{this} {
    Claim Omar lives in "New Jersey"
}}
Step

assert {[count [list /someone/ claims /p/ is a place where Omar lives]] == 3}

set ::outlinecolors [dict create]
Assert someone wishes BlueThing is outlined blue
Assert someone claims BlueThing has region BlueThingRegion
Assert when /someone/ wishes /thing/ is outlined /color/ {{thing color} {
    When $thing has region /r/ {
        dict set ::outlinecolors $thing $color
    }
}}
set ::joinoutlinecolors [dict create]
Assert programJoin has program {{this} {
    When /someone/ wishes /thing/ is outlined /color/ & /thing/ has region /r/ {
        dict set ::joinoutlinecolors $thing $color
    }
}}
Assert someone wishes GreenThing is outlined green
Assert someone claims GreenThing has region GreenThingRegion
Step

assert {$::outlinecolors eq "BlueThing blue GreenThing green"}
assert {$::outlinecolors eq $::joinoutlinecolors}

Assert someone claims BlueThing has region BlueThingRegion2
Retract someone claims BlueThing has region BlueThingRegion
Step

assert {$::outlinecolors eq "BlueThing blue GreenThing green"}
assert {$::outlinecolors eq $::joinoutlinecolors}

Assert "New York" is a city
Assert "New York" is where the studio is
Assert "New York" is where Omar lives
set ::properties [list]
Assert when the program is running {{} {
    When "New York" is /...property/ {
        lappend ::properties $property
    }
}}
Assert the program is running
Step
# TODO: this would ideally sort
assert {$::properties eq {{a city} {where the studio is} {where Omar lives} {a place where Omar lives}}}

Retract the program is running
Step

