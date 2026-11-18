# pretty-dot.tcl -- relabel a state graph dumped by TLC so it can be read.
#
# Usage: jimsh pretty-dot.tcl IN.dot OUT.dot
#
# TLC labels each node with the full state. This keeps what tells the
# states of Folk.tla apart: what is held, which statements are present and
# with how many parents, which matches exist, and what is queued.

lassign $argv in out
set fd [open $in r]; set text [read $fd]; close $fd

proc field {state name} {
    # The value of `/\ name = ...` up to the next conjunct.
    if {![regexp "/\\\\\\\\ $name = (.*?)(?:\\\\n/\\\\\\\\ |\$)" $state -> value]} { return "" }
    return [string map [list "\\n" " "] $value]
}

proc describe {state} {
    set lines {}

    set held {}
    foreach {_ key clause} [regexp -all -inline {(\w+) :> (\w+)} [field $state held]] {
        if {$clause ne "None"} { lappend held $clause }
    }
    lappend lines "held: [expr {[llength $held] ? [join $held { }] : {nothing}}]"

    set present {}
    foreach {_ clause n} [regexp -all -inline {(\w+) :> (\d+)} [field $state count]] {
        if {$n > 0} { lappend present "$clause (parents: $n)" }
    }
    lappend lines "in db: [expr {[llength $present] ? [join $present {, }] : {nothing}}]"

    set dying [regexp -all -inline {\d+} [field $state dying]]
    set i 0
    foreach {_ parent rule} [regexp -all -inline {parent \|-> (\w+), pgen \|-> \d+, rule \|-> (\w+)} [field $state matches]] {
        incr i
        lappend lines "match $rule on $parent: [expr {$i in $dying ? {parent gone} : {live}}]"
    }

    set gens [dict create]
    foreach {_ clause g} [regexp -all -inline {(\w+) :> (\d+)} [field $state gen]] {
        dict set gens $clause $g
    }
    set counts [dict create]
    foreach {_ clause n} [regexp -all -inline {(\w+) :> (\d+)} [field $state count]] {
        dict set counts $clause $n
    }
    set queued {}
    foreach {_ rule clause g n} [regexp -all -inline {<<(\w+), (\w+), (\d+)>> :> (\d+)} [field $state queue]] {
        if {$n == 0} { continue }
        set stale [expr {[dict get $counts $clause] == 0 || [dict get $gens $clause] != $g}]
        set item "run $rule on $clause[expr {$stale ? { (stale)} : {}}]"
        if {$item ni $queued} { lappend queued $item }
    }
    if {[llength $queued]} { lappend lines "queued: [join $queued {, }]" }
    return [join $lines "\\n"]
}

set outText {}
foreach line [split $text "\n"] {
    if {![regexp {^-?\d+ -> -?\d+} $line] &&
        [regexp {^(-?\d+) \[label="(.*)"(.*)\];?$} $line -> id state rest]} {
        lappend outText "$id \[label=\"[describe $state]\"$rest\];"
    } else {
        # Edge labels: drop the generation from RunWhen(<<r, c, g>>), and
        # name the two actions TLC only reports as "Next".
        regsub {RunWhen\(<<(\w+), (\w+), \d+>>\)} $line {run \1 on \2} line
        regsub {label="Next"} $line {label="release match"} line
        regsub {Hold\(\w+,(\w+)\)} $line {Hold! \1} line
        regsub {Unhold\(\w+\)} $line {clear hold} line
        lappend outText $line
    }
}
set fd [open $out w]; puts $fd [join $outText "\n"]; close $fd
