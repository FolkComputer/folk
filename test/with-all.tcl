proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

Assert program1 has program code {
    set ::collectedMatches [dict create]
    proc ::updateCollectedMatches {clause} {
	set matches [dict get $::collectedMatches $clause]
	Retract the collected matches for $clause are /something/
	Assert the collected matches for $clause are [dict keys $matches]
	Step
    }
    When /someone/ wishes to collect matches for /clause/ {
        set varNames [lmap word $clause {expr {
            [regexp {^/([^/ ]+)/$} $word -> varName] ? $varName : [continue]
        }}]
        When {*}$clause {
            set match [dict create]
            foreach varName $varNames { dict set match $varName [set $varName] }

            dict set ::collectedMatches $clause $match true
            ::updateCollectedMatches $clause

            On unmatch [subst {
                dict unset ::collectedMatches {$clause} {$match}
                ::updateCollectedMatches {$clause}
            }]
	}
        On unmatch { dict unset ::collectedMatches $clause }
    }
}

Assert programOakland has program code {
    Claim Omar lives in "Oakland"
}
Assert program3 has program code {
    Wish to collect matches for [list Omar lives in /place/]
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

Retract programOakland has program code /something/
Step

assert {[countCollectedMatches [list Omar lives in /place/]] == 1}
