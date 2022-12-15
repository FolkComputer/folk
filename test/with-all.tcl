Assert program1 has program code {
    set ::collectedMatches [dict create]
    proc ::updateCollectedMatches {clause} {
	set matches [dict get $::collectedMatches $clause]
	Retract the collected matches for $clause are /something/
	Assert the collected matches for $clause are [dict keys $matches]
	Step
    }
    When /someone/ wishes to collect matches for /clause/ {
         When {*}$clause {
             puts "$clause -> $__env"

		dict set ::collectedMatches $clause $__env true
		::updateCollectedMatches $clause

		On unmatch [subst {
			dict unset ::collectedMatches {$clause} {$__env}
			::updateCollectedMatches {$clause}
		}]
	}
    }
}

Assert program3 has program code {
    Claim Omar lives in "Oakland"
}
Assert program2 has program code {
    Wish to collect matches for [list Omar lives in /place/]
}
Assert program3 has program code {
    Claim Omar lives in "New York"
}

Step
