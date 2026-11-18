# timeline.tcl -- draws a few milliseconds of a Tracy capture as an SVG.
#
# Usage: jimsh timeline.tcl EVENTS.csv OUT.svg ?START_FRACTION? ?WINDOW_MS?
#
# EVENTS.csv is `tracy-csvexport -u trace.tracy`: one line per zone with
# its start time, duration and thread. Two panels share a time axis:
#   rule bodies   one row per rule (a zone named file:line), a mark for
#                 every run of its body
#   workers       one row per thread, a mark for every RUN_WHEN work item
# START_FRACTION picks where in the run the window starts (default 0.6);
# WINDOW_MS is its length (default 4).
#
# One hue throughout: position carries rule and worker, so colour has no
# second job. The marks carry their numbers as SVG <title> tooltips, and
# the same numbers are in the CSV next to this file.

lassign $argv eventsPath outPath startFraction windowMs
if {$startFraction eq ""} { set startFraction 0.6 }
if {$windowMs eq ""} { set windowMs 4.0 }

# ---- Read ----

set fd [open $eventsPath r]
set events {}
set first 1
set tMin ""; set tMax 0
foreach line [split [read $fd] "\n"] {
    if {$first} { set first 0; continue }
    set fields [split $line ","]
    if {[llength $fields] != 6} { continue }
    lassign $fields name file lineno start duration thread
    lappend events [list $name $file $lineno $start $duration $thread]
    if {$tMin eq "" || $start < $tMin} { set tMin $start }
    if {$start > $tMax} { set tMax $start }
}
close $fd

set w0 [expr {$tMin + ($tMax - $tMin) * $startFraction}]
set w1 [expr {$w0 + $windowMs * 1e6}]

# Marks inside the window, clipped to it.
set ruleMarks [dict create]     ;# "file:line" -> list of {start duration thread}
set workerMarks [dict create]   ;# thread -> list of {start duration what}
foreach event $events {
    lassign $event name file lineno start duration thread
    set end [expr {$start + $duration}]
    if {$end < $w0 || $start > $w1} { continue }
    if {[string match *.folk $file]} {
        dict lappend ruleMarks "$file:$lineno" [list $start $duration $thread]
    } elseif {$name eq "RUN_WHEN"} {
        dict lappend workerMarks $thread [list $start $duration $name]
    }
}

# The text of a rule's first line, to label its row.
proc sourceLine {where} {
    regexp {^(.*):(\d+)$} $where -> file lineno
    if {[catch {open $file r} fd]} { return "" }
    set lines [split [read $fd] "\n"]
    close $fd
    set text [string trim [lindex $lines $lineno-1]]
    regsub {\s*\{\s*$} $text {} text
    if {[string length $text] > 44} { set text "[string range $text 0 42]..." }
    return $text
}
proc xmlEscape {text} {
    string map {& &amp; < &lt; > &gt; \" &quot;} $text
}

# ---- Layout ----

set width 980
set left 300          ;# row labels
set right 150         ;# per-row summary
set plotW [expr {$width - $left - $right}]
set rowH 30
set barH 14
set top 76

proc sortByLine {keys} {
    lsort -command {apply {{a b} {
        regexp {:(\d+)$} $a -> la; regexp {:(\d+)$} $b -> lb
        expr {$la - $lb}
    }}} $keys
}
set ruleRows [sortByLine [dict keys $ruleMarks]]
set workerRows [lsort -integer [dict keys $workerMarks]]

set panelGap 54
set rulesTop $top
set workersTop [expr {$rulesTop + [llength $ruleRows] * $rowH + $panelGap}]
set axisY [expr {$workersTop + [llength $workerRows] * $rowH + 8}]
set height [expr {$axisY + 44}]

proc xOf {t} {
    global w0 w1 left plotW
    expr {$left + ($t - $w0) / double($w1 - $w0) * $plotW}
}

set svg {}
lappend svg "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 $width $height\" width=\"$width\" height=\"$height\" role=\"img\" aria-labelledby=\"title desc\">"
lappend svg "<title id=\"title\">Execution timeline of the pipeline benchmark</title>"
lappend svg "<desc id=\"desc\">Which rule body ran when, and on which worker thread, over $windowMs milliseconds of a Tracy capture.</desc>"
lappend svg {<style>
  svg { --surface: #fcfcfb; --ink: #0b0b0b; --ink2: #52514e; --muted: #898781;
        --grid: #e1e0d9; --axis: #c3c2b7; --mark: #2a78d6;
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
  @media (prefers-color-scheme: dark) {
    svg { --surface: #1a1a19; --ink: #f0efec; --ink2: #c3c2b7; --muted: #898781;
          --grid: #2c2c2a; --axis: #383835; --mark: #3987e5; }
  }
  .surface { fill: var(--surface); }
  .title { fill: var(--ink); font-size: 16px; font-weight: 600; }
  .subtitle { fill: var(--ink2); font-size: 12px; }
  .panel { fill: var(--ink2); font-size: 11px; font-weight: 600; letter-spacing: 0.04em; }
  .row { fill: var(--ink); font-size: 12px; }
  .where { fill: var(--muted); font-size: 11px; }
  .tick { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
  .summary { fill: var(--ink2); font-size: 11px; font-variant-numeric: tabular-nums; }
  .grid { stroke: var(--grid); stroke-width: 1; }
  .axis { stroke: var(--axis); stroke-width: 1; }
  .mark { fill: var(--mark); }
  .mark:hover { opacity: 0.75; }
</style>}
lappend svg "<rect class=\"surface\" width=\"$width\" height=\"$height\"/>"
lappend svg "<text class=\"title\" x=\"16\" y=\"26\">$windowMs ms of the pipeline benchmark: which rule body ran when</text>"
lappend svg "<text class=\"subtitle\" x=\"16\" y=\"45\">Tracy zones from the stock runtime. Each mark is one run of a rule body (top) or one work item on a worker thread (bottom).</text>"

# Gridlines and ticks every half millisecond.
for {set ms 0.0} {$ms <= $windowMs + 1e-9} {set ms [expr {$ms + 0.5}]} {
    set x [format %.1f [xOf [expr {$w0 + $ms * 1e6}]]]
    lappend svg "<line class=\"grid\" x1=\"$x\" x2=\"$x\" y1=\"[expr {$rulesTop - 6}]\" y2=\"$axisY\"/>"
    set label [expr {$ms == int($ms) ? "[expr {int($ms)}] ms" : ""}]
    if {$label ne ""} {
        lappend svg "<text class=\"tick\" x=\"$x\" y=\"[expr {$axisY + 16}]\" text-anchor=\"middle\">$label</text>"
    }
}
lappend svg "<line class=\"axis\" x1=\"$left\" x2=\"[expr {$left + $plotW}]\" y1=\"$axisY\" y2=\"$axisY\"/>"

# One row of marks. Returns {count meanMicros busyFraction}.
proc drawRow {y marks tooltipPrefix} {
    global svg w0 w1 barH rowH
    set count 0; set total 0; set busy 0
    foreach mark [lsort -real -index 0 $marks] {
        lassign $mark start duration extra
        incr count
        set total [expr {$total + $duration}]
        set a [expr {$start > $w0 ? $start : $w0}]
        set b [expr {$start + $duration < $w1 ? $start + $duration : $w1}]
        set busy [expr {$busy + ($b - $a)}]
        # A 1px inset each side leaves a 2px surface gap between marks
        # that touch.
        set x [expr {[xOf $a] + 1}]
        set w [expr {[xOf $b] - [xOf $a] - 2}]
        if {$w < 1.5} { set w 1.5 }
        set r [expr {$w >= 8 ? 3 : 1}]
        set tip "$tooltipPrefix: [format %.0f [expr {$duration / 1000.0}]] us, starting at [format %.3f [expr {($start - $w0) / 1e6}]] ms"
        if {$extra ne "" && [string is integer -strict $extra]} { append tip ", thread $extra" }
        lappend svg "<rect class=\"mark\" x=\"[format %.1f $x]\" y=\"[expr {$y + ($rowH - $barH) / 2}]\" width=\"[format %.1f $w]\" height=\"$barH\" rx=\"$r\"><title>[xmlEscape $tip]</title></rect>"
    }
    set mean [expr {$count ? $total / $count / 1000.0 : 0}]
    return [list $count $mean [expr {$busy / double($w1 - $w0)}]]
}

# Panel 1: rule bodies.
lappend svg "<text class=\"panel\" x=\"16\" y=\"[expr {$rulesTop - 10}]\">RULE BODIES</text>"
set y $rulesTop
foreach where $ruleRows {
    set mid [expr {$y + $rowH / 2}]
    lappend svg "<text class=\"row\" x=\"16\" y=\"[expr {$mid - 1}]\">[xmlEscape [sourceLine $where]]</text>"
    lappend svg "<text class=\"where\" x=\"16\" y=\"[expr {$mid + 12}]\">[xmlEscape $where]</text>"
    lassign [drawRow $y [dict get $ruleMarks $where] $where] count mean busy
    lappend svg "<text class=\"summary\" x=\"[expr {$left + $plotW + 12}]\" y=\"[expr {$mid + 4}]\">$count runs, [format %.0f $mean] us mean</text>"
    incr y $rowH
}

# Panel 2: workers.
lappend svg "<text class=\"panel\" x=\"16\" y=\"[expr {$workersTop - 10}]\">WORKER THREADS (work items of kind RUN_WHEN)</text>"
set y $workersTop
foreach thread $workerRows {
    set mid [expr {$y + $rowH / 2}]
    lappend svg "<text class=\"row\" x=\"16\" y=\"[expr {$mid + 4}]\">thread $thread</text>"
    lassign [drawRow $y [dict get $workerMarks $thread] "thread $thread"] count mean busy
    lappend svg "<text class=\"summary\" x=\"[expr {$left + $plotW + 12}]\" y=\"[expr {$mid + 4}]\">busy [format %.0f [expr {$busy * 100}]]% of the window</text>"
    incr y $rowH
}
lappend svg "</svg>"

set fd [open $outPath w]
puts $fd [join $svg "\n"]
close $fd
puts "wrote $outPath: [llength $ruleRows] rules, [llength $workerRows] threads"
