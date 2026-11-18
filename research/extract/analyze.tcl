# analyze.tcl -- static analysis of a tree of Folk programs.
#
# Usage: jimsh research/extract/analyze.tcl ?-root DIR? ?-out DIR?
#
# Reads boot.folk, builtin-programs/ and user-programs/ under the root (and
# test/ for the metrics only), recognises the Folk forms in them without
# evaluating anything, and writes into the output directory:
#
#   forms.tsv         one line per form
#   metrics.txt       corpus counts
#   diagnostics.tsv   grammar violations and pattern lints
#   emissions.tsv     every statement shape a program can emit
#   generic.tsv       patterns and statements with no literal word
#   unmatched.tsv     patterns that no emission in the tree can match
#   unhandled.tsv     wishes that nothing in the tree reads
#   polled.tsv        wishes read only by Query! and ForEach!, never by a rule
#   cycles.txt        rule cycles and rules that negate their own output
#   capture.tsv       variables captured vs. used, per rule body
#   prefix-fires.tsv  statements that fire a /...rest/ rule they do not match
#   interfaces.tsv    every statement shape with its producers and readers
#   undefined-commands.tsv  commands called but defined nowhere
#   subsystems.dot    programs.dot folded by directory
#   programs.dot      which program's statements reach which program
#   rules.dot         the same, per rule
#
# Statement shapes are abstract: a term whose value is computed at run time
# is a hole that matches anything, so every result here over-approximates
# what can match and under-approximates what is dead.

set here [file dirname [info script]]
source $here/folkforms.tcl

set root .
set out research/out
foreach {option value} $argv {
    switch -- $option {
        -root { set root $value }
        -out { set out $value }
        default { puts stderr "unknown option $option"; exit 2 }
    }
}
file mkdir $out

# ---- Corpus ----

proc globTree {dir} {
    set files {}
    foreach path [lsort [glob -nocomplain -directory $dir *]] {
        if {[file isdirectory $path]} {
            if {[file tail $path] eq "_archive"} { continue }
            lappend files {*}[globTree $path]
        } elseif {[string match *.folk $path]} {
            lappend files $path
        }
    }
    return $files
}

# What boot.folk loads: builtin-programs one and two levels deep, and each
# host's own directory under user-programs. Anything deeper is on disk but
# never loaded, so it is listed and left out.
proc loadedBy {files base maxDepth} {
    set kept {}
    foreach path $files {
        set rel [string range $path [string length $base]+1 end]
        if {[llength [split $rel /]] <= $maxDepth} { lappend kept $path }
    }
    return $kept
}
set allBuiltin [globTree $root/builtin-programs]
set allUser [globTree $root/user-programs]
set builtinFiles [loadedBy $allBuiltin $root/builtin-programs 2]
set userFiles [loadedBy $allUser $root/user-programs 2]
set systemFiles [list $root/boot.folk {*}$builtinFiles {*}$userFiles]
set notLoaded {}
foreach path [concat $allBuiltin $allUser] {
    if {$path ni $systemFiles} { lappend notLoaded $path }
}
set testFiles [globTree $root/test]

proc relative {path} {
    global root
    if {[string first "$root/" $path] == 0} {
        return [string range $path [string length "$root/"] end]
    }
    return $path
}

proc lineCount {path} {
    set fd [open $path r]
    set n [llength [split [read $fd] "\n"]]
    close $fd
    return $n
}

ff::reset
set fileLines [dict create]
foreach path [concat $systemFiles $testFiles] {
    set name [relative $path]
    dict set fileLines $name [lineCount $path]
    ff::walkFile $path $name
}
set forms [ff::forms]
set isTest [dict create]
foreach path $testFiles { dict set isTest [relative $path] 1 }

proc inSystem {form} {
    global isTest
    expr {![dict exists $isTest [dict get $form file]]}
}

# ---- Rendering ----

proc termText {term} {
    lassign $term type value
    switch $type {
        lit {
            if {$value eq "" || [regexp {[ \n\t]} $value]} {
                set flat [string map [list "\n" " " "\t" " "] $value]
                if {[string length $flat] > 30} {
                    set flat "[string range $flat 0 26]..."
                }
                return "{$flat}"
            }
            return $value
        }
        var { return "/$value/" }
        rest { return "/...$value/" }
        wild { return "/$value/" }
        neg { return "/$value/" }
        hole - splat - this {
            set flat [string map [list "\n" " " "\t" " "] $value]
            if {[string length $flat] > 30} {
                set flat "[string range $flat 0 26]..."
            }
            return $flat
        }
    }
}
proc clauseText {clause} {
    join [lmap term $clause { termText $term }] " "
}
# The clause with everything but its literal words blanked out.
proc skeleton {clause} {
    join [lmap term $clause {
        lassign $term type value
        if {$type eq "lit" && ![regexp {[ \n\t]} $value] && $value ne ""} {
            set value
        } elseif {$type in {rest splat}} {
            expr {"..."}
        } else {
            expr {"_"}
        }
    }] " "
}
proc where {form} { return "[dict get $form file]:[dict get $form line]" }

# ---- Emissions and consumers ----

# A statement shape that the tree can put in the database.
#   {formId scopeId kind terms}
# scopeId is the rule whose body contains the emitting form (-1: top level
# of the program).
set emissions {}
# A pattern that is matched against the database.
#   {formId scopeId kind terms}   kind: when collected query retract
set consumers {}
# Events are a separate namespace: Notify: only reaches Subscribe:.
set notifies {}
set subscribes {}

# The implicit subject of Claim and Wish. Its value is a program's name (a
# file path or a tag id), so unlike other holes it is not allowed to stand
# for an arbitrary literal word of a pattern; see unifies.
set THIS {this {$this}}

# The nearest enclosing form that is a rule (something whose body runs as
# a consequence of a match), or -1.
proc ruleOf {id} {
    global forms
    while {$id >= 0} {
        set form [lindex $forms $id]
        if {[dict get $form kind] in {when subscribe}} { return $id }
        if {[dict get $form kind] eq "hold" && [dict get $form body]} {
            return $id
        }
        set id [dict get $form parent]
    }
    return -1
}

proc hasNeg {clause} {
    foreach term $clause {
        if {[lindex $term 0] eq "neg"} { return 1 }
    }
    return 0
}
proc unNeg {clause} {
    lmap term $clause {
        if {[lindex $term 0] eq "neg"} { list wild any } else { set term }
    }
}

foreach form $forms {
    if {![inSystem $form]} { continue }
    set id [dict get $form id]
    set scope [ruleOf [dict get $form parent]]
    set clauses [dict get $form clauses]
    if {[dict exists $form embedded]} {
        # A pattern passed as data, in practice always to the collector.
        set owner [expr {[dict get $form kind] eq "when" ? $id : $scope}]
        foreach pattern [dict get $form embedded] {
            lappend consumers [list $id $owner collected [unNeg $pattern]]
        }
    }
    switch [dict get $form kind] {
        claim {
            lappend emissions [list $id $scope claim \
                [list $THIS {lit claims} {*}[lindex $clauses 0]]]
        }
        wish {
            lappend emissions [list $id $scope wish \
                [list $THIS {lit wishes} {*}[lindex $clauses 0]]]
        }
        say - assert {
            lappend emissions [list $id $scope say [lindex $clauses 0]]
        }
        hold {
            # -on and -key only name the hold; the statement is still made
            # with the caller's $this.
            switch [dict get $form emits] {
                claim {
                    lappend emissions [list $id $scope hold \
                        [list $THIS {lit claims} {*}[lindex $clauses 0]]]
                }
                wish {
                    lappend emissions [list $id $scope hold \
                        [list $THIS {lit wishes} {*}[lindex $clauses 0]]]
                }
                say {
                    lappend emissions [list $id $scope hold [lindex $clauses 0]]
                }
            }
        }
        when {
            # A rule is itself a statement, and each clause after the
            # first becomes a nested rule when the one before it matches.
            set i 0
            foreach clause $clauses {
                if {[hasNeg $clause]} {
                    set pattern [unNeg $clause]
                    lappend consumers [list $id $id collected $pattern]
                    set stored [list {lit the} {lit collected} {lit results} \
                                    {lit for} {hole pattern} {lit are} \
                                    {var __results}]
                } else {
                    lappend consumers [list $id $id when $clause]
                    set stored $clause
                }
                lappend emissions [list $id [expr {$i == 0 ? $scope : $id}] \
                    rule [list {lit when} {*}$stored {hole body} {lit with} \
                              {lit environment} {hole env}]]
                incr i
            }
            if {[dict exists $form collected]} {
                lappend consumers [list $id $id collected \
                                       [dict get $form collected]]
            }
        }
        query {
            foreach clause $clauses {
                if {[hasNeg $clause]} { set clause [unNeg $clause] }
                lappend consumers [list $id $scope query $clause]
            }
        }
        retract {
            lappend consumers [list $id $scope retract [lindex $clauses 0]]
        }
        notify { lappend notifies [list $id $scope [lindex $clauses 0]] }
        subscribe { lappend subscribes [list $id $id [lindex $clauses 0]] }
    }
}

# Statements put in the database by C code or by prelude.tcl, which this
# tool does not parse. Found by reading sysmon.c, collect.folk and
# prelude.tcl; extend the list if you add more.
set externals {
    {sysmon.c           {{lit sysmon.c} {lit claims} {lit the} {lit internal} {lit time} {lit is} {hole t}}}
    {sysmon.c           {{lit sysmon.c} {lit claims} {lit the} {lit clock} {lit time} {lit is} {hole t}}}
    {sysmon.c           {{lit sysmon.c} {lit claims} {hole node} {lit has} {lit self} {lit RAM} {lit usage} {hole mb} {lit MB}}}
    {sysmon.c           {{lit sysmon.c} {lit claims} {hole node} {lit has} {lit available} {lit RAM} {hole mb} {lit MB} {lit of} {hole total} {lit MB}}}
    {collect.folk(C)    {{lit builtin-programs/collect.folk} {lit claims} {lit the} {lit collected} {lit results} {lit for} {hole pattern} {lit are} {hole results}}}
    {prelude.tcl        {{hole this} {lit has} {lit error} {hole err} {lit with} {lit info} {hole opts}}}
}
set externalBase -1000
set i 0
foreach external $externals {
    lassign $external source terms
    lappend emissions [list [expr {$externalBase - $i}] -1 external $terms]
    incr i
}

# ---- Matching ----

# A pattern or statement with no literal word says nothing about what it
# matches (`When {*}$pattern`, `Claim {*}$clause`). Such forms are listed in
# generic.tsv and kept out of the matching, where they would connect
# everything to everything.
proc literalWords {terms} {
    set n 0
    foreach term $terms {
        if {[lindex $term 0] eq "lit"} { incr n }
    }
    return $n
}
proc isGeneric {kind terms} {
    if {$kind in {claim wish hold} &&
        [lindex $terms 1 0] eq "lit" && [lindex $terms 1 1] in {claims wishes}} {
        set terms [lrange $terms 2 end]
    }
    if {$kind eq "rule"} { set terms [lrange $terms 1 end-4] }
    expr {[literalWords $terms] == 0}
}

# Can pattern p match statement s? Both are term lists; holes and variables
# on either side match anything (the trie treats a stored /x/ as a
# variable too, see trieLookupImpl in trie.c).
proc unifies {p s} {
    set np [llength $p]
    set ns [llength $s]
    for {set i 0} {1} {incr i} {
        if {$i < $np} {
            lassign [lindex $p $i] ptype pvalue
            if {$ptype eq "splat"} { return 1 }
            if {$ptype eq "rest"} {
                # Needs at least one term to bind.
                if {$i < $ns} { return 1 }
                return 0
            }
        }
        if {$i < $ns} {
            lassign [lindex $s $i] stype svalue
            if {$stype eq "splat"} { return 1 }
            if {$stype eq "rest"} { return [expr {$i < $np}] }
        }
        if {$i >= $np || $i >= $ns} {
            return [expr {$np == $ns}]
        }
        if {$ptype eq "lit" && $stype eq "lit" && $pvalue ne $svalue} {
            return 0
        }
        if {$ptype eq "lit" && $stype eq "this"} {
            # `$this claims ...` only meets a literal first word when the
            # pattern names the claimer outright: `sysmon.c claims ...`.
            lassign [lindex $p 1] nextType nextValue
            if {!($nextType eq "lit" && $nextValue in {claims wishes})} {
                return 0
            }
        }
    }
}

# A pattern whose second term is not `claims` or `wishes` also matches
# `/someone/ claims <pattern>` (claimizeClause in folk.c).
proc claimizable {p} {
    if {[llength $p] > 2} {
        lassign [lindex $p 1] type value
        if {$type eq "lit" && $value in {claims wishes}} { return 0 }
    }
    return 1
}
proc matches {p s} {
    if {[unifies $p $s]} { return 1 }
    if {[claimizable $p] &&
        [unifies [list {wild someone} {lit claims} {*}$p] $s]} { return 1 }
    return 0
}

# Index emissions by their first two literal words to keep the pairwise
# matching fast. A key of "*" means "not a literal".
proc key2 {terms} {
    set keys {}
    foreach term [lrange $terms 0 1] {
        lassign $term type value
        lappend keys [expr {$type eq "lit" ? $value : "*"}]
    }
    return $keys
}

puts stderr "matching [llength $consumers] patterns against [llength $emissions] emissions..."

# consumerHits: consumer index -> list of emission indices
# emissionHits: emission index -> list of consumer indices
set consumerHits [dict create]
set emissionHits [dict create]
for {set c 0} {$c < [llength $consumers]} {incr c} {
    dict set consumerHits $c {}
}
for {set e 0} {$e < [llength $emissions]} {incr e} {
    dict set emissionHits $e {}
}
set genericConsumers {}
set genericEmissions {}
for {set e 0} {$e < [llength $emissions]} {incr e} {
    if {[isGeneric [lindex $emissions $e 2] [lindex $emissions $e 3]]} {
        dict set genericEmissions $e 1
    }
}
for {set c 0} {$c < [llength $consumers]} {incr c} {
    set pattern [lindex $consumers $c 3]
    if {[literalWords $pattern] == 0} {
        dict set genericConsumers $c 1
        continue
    }
    for {set e 0} {$e < [llength $emissions]} {incr e} {
        if {[dict exists $genericEmissions $e]} { continue }
        if {[matches $pattern [lindex $emissions $e 3]]} {
            dict lappend consumerHits $c $e
            dict lappend emissionHits $e $c
        }
    }
}

# ---- Output: forms ----

set fd [open $out/forms.tsv w]
puts $fd "id\tkind\tcmd\tfile\tline\tparent\topts\tclauses"
foreach form $forms {
    dict with form {
        puts $fd "$id\t$kind\t$cmd\t$file\t$line\t$parent\t$opts\t[join [lmap c $clauses { clauseText $c }] { & }]"
    }
}
close $fd

# ---- Output: metrics ----

proc count {dictVar key {by 1}} {
    upvar $dictVar d
    if {![dict exists $d $key]} { dict set d $key 0 }
    dict set d $key [expr {[dict get $d $key] + $by}]
}
proc topN {d n} {
    set pairs {}
    dict for {key value} $d { lappend pairs [list $value $key] }
    lrange [lsort -decreasing -integer -index 0 $pairs] 0 $n-1
}

set m [open $out/metrics.txt w]
set systemLines 0
foreach path $systemFiles { incr systemLines [dict get $fileLines [relative $path]] }
set testLines 0
foreach path $testFiles { incr testLines [dict get $fileLines [relative $path]] }
puts $m "Corpus"
puts $m "  system programs  [llength $systemFiles] files, $systemLines lines"
puts $m "    boot.folk + [llength $builtinFiles] builtin-programs + [llength $userFiles] user-programs (all hosts)"
puts $m "  tests            [llength $testFiles] files, $testLines lines"
foreach path $notLoaded {
    puts $m "  not loaded by boot.folk (too deep): [relative $path]"
}
foreach entry [ff::unreachable] {
    lassign $entry file line n
    puts $m "  switched off by `return` at $file:$line ($n commands not analysed)"
}
puts $m ""

set byCmd {}; set byCmdTest {}
set optUse {}
set whenClauses {}; set whenStatic 0; set whenHoles 0; set whenSplat 0
set whenTotal 0; set whenNeg 0; set whenRest 0; set whenEmpty 0
set arity {}
set termKinds {}
set skeletons {}
set depthHist {}
set bodyless 0
foreach form $forms {
    set kind [dict get $form kind]
    if {$kind in {proc handler}} { continue }
    if {![inSystem $form]} { count byCmdTest [dict get $form cmd]; continue }
    count byCmd [dict get $form cmd]
    dict for {option value} [dict get $form opts] {
        count optUse "[dict get $form cmd] $option"
    }
    if {$kind eq "when"} {
        incr whenTotal
        set clauses [dict get $form clauses]
        count whenClauses [llength $clauses]
        set static 1; set splat 0
        foreach clause $clauses {
            foreach term $clause {
                switch [lindex $term 0] {
                    hole { set static 0 }
                    splat { set static 0; set splat 1 }
                }
            }
            if {[hasNeg $clause]} { incr whenNeg }
            foreach term $clause {
                if {[lindex $term 0] eq "rest"} { incr whenRest; break }
            }
        }
        if {[llength $clauses] == 1 && [llength [lindex $clauses 0]] == 0} {
            incr whenEmpty
        }
        if {$static} { incr whenStatic } elseif {$splat} { incr whenSplat } else { incr whenHoles }
        # Nesting depth: how many rules enclose this one.
        set depth 0
        set p [dict get $form parent]
        while {$p >= 0} {
            if {[dict get [lindex $forms $p] kind] eq "when"} { incr depth }
            set p [dict get [lindex $forms $p] parent]
        }
        count depthHist $depth
        if {![dict get $form body]} { incr bodyless }
    }
    foreach clause [dict get $form clauses] {
        if {[llength $clause] == 0} { continue }
        count arity [llength $clause]
        foreach term $clause { count termKinds [lindex $term 0] }
        if {$kind in {when claim wish hold say assert}} {
            count skeletons [skeleton $clause]
        }
    }
}

puts $m "Forms in system programs (tests in brackets)"
foreach pair [topN $byCmd 100] {
    lassign $pair n cmd
    set t [expr {[dict exists $byCmdTest $cmd] ? [dict get $byCmdTest $cmd] : 0}]
    puts $m [format "  %-14s %5d  \[%d\]" $cmd $n $t]
}
puts $m ""
puts $m "Options"
foreach pair [topN $optUse 100] {
    lassign $pair n option
    puts $m [format "  %-28s %5d" $option $n]
}
puts $m ""
puts $m "When (and Assert! when) rules: $whenTotal"
puts $m "  pattern fully literal                $whenStatic"
puts $m "  pattern has run-time values (holes)  $whenHoles"
puts $m "  pattern has a {*} expansion          $whenSplat"
puts $m "  empty pattern (runs immediately)     $whenEmpty"
puts $m "  clauses with /nobody/ or /nothing/   $whenNeg"
puts $m "  clauses with a /...rest/ variable    $whenRest"
puts $m "  body not a braced literal            $bodyless"
puts $m "  clauses per rule (joins):"
foreach n [lsort -integer [dict keys $whenClauses]] {
    puts $m [format "    %d clause(s)  %5d" $n [dict get $whenClauses $n]]
}
puts $m "  rules enclosing this rule (nesting depth):"
foreach n [lsort -integer [dict keys $depthHist]] {
    puts $m [format "    depth %d      %5d" $n [dict get $depthHist $n]]
}
puts $m ""
puts $m "Terms per clause"
foreach n [lsort -integer [dict keys $arity]] {
    puts $m [format "  %2d terms  %5d" $n [dict get $arity $n]]
}
puts $m ""
puts $m "Term kinds over all clauses"
foreach pair [topN $termKinds 100] {
    lassign $pair n kind
    puts $m [format "  %-6s %6d" $kind $n]
}
puts $m ""
puts $m "Statement vocabulary: [dict size $skeletons] distinct clause skeletons"
puts $m "(literal words kept, everything else shown as _; top 40)"
foreach pair [topN $skeletons 40] {
    lassign $pair n skeleton
    puts $m [format "  %4d  %s" $n $skeleton]
}
close $m

# ---- Output: diagnostics ----

set fd [open $out/diagnostics.tsv w]
puts $fd "code\twhere\tform\tmessage"
set diagCounts {}
foreach form $forms {
    foreach diag [dict get $form diags] {
        lassign $diag code message
        set text [join [lmap c [dict get $form clauses] { clauseText $c }] { & }]
        puts $fd "$code\t[where $form]\t[dict get $form cmd] $text\t$message"
        count diagCounts $code
    }
}
foreach error [ff::parseErrors] {
    lassign $error file char line
    puts $fd "unterminated\t$file:$line\t\tunterminated $char"
    count diagCounts unterminated
}
close $fd

# ---- Output: emissions, unmatched patterns, unhandled wishes ----

proc emissionWhere {emission} {
    global forms externals externalBase
    set id [lindex $emission 0]
    if {$id <= $externalBase} {
        return [lindex $externals [expr {$externalBase - $id}] 0]
    }
    return [where [lindex $forms $id]]
}

set fd [open $out/emissions.tsv w]
puts $fd "where\tkind\tstatement\tmatching_patterns"
for {set e 0} {$e < [llength $emissions]} {incr e} {
    set emission [lindex $emissions $e]
    puts $fd "[emissionWhere $emission]\t[lindex $emission 2]\t[clauseText [lindex $emission 3]]\t[llength [dict get $emissionHits $e]]"
}
close $fd

# For a pattern nothing matches, look for its wording elsewhere in the tree:
# statements can also be made from JavaScript in web pages, from C, or by
# code built as a string, none of which the recogniser sees.
proc readFile {path} {
    set fd [open $path r]
    set text [read $fd]
    close $fd
    return $text
}
set haystack {}
foreach path [concat $systemFiles $testFiles [glob -nocomplain $root/*.c] \
                  [glob -nocomplain $root/*.tcl] [glob -nocomplain $root/lib/*]] {
    set n 0
    foreach text [split [readFile $path] "\n"] {
        incr n
        lappend haystack [list [relative $path] $n $text]
    }
}
# The longest run of consecutive literal words in a pattern.
proc phrase {pattern} {
    set best {}
    set run {}
    foreach term [concat $pattern {{end {}}}] {
        lassign $term type value
        if {$type eq "lit" && $value ni {claims wishes} &&
            ![regexp {[ \n\t]} $value] && $value ne ""} {
            lappend run $value
        } else {
            if {[llength $run] > [llength $best]} { set best $run }
            set run {}
        }
    }
    return [join $best " "]
}
set emissionLines [dict create]
foreach emission $emissions {
    set id [lindex $emission 0]
    if {$id >= 0} { dict set emissionLines [where [lindex $forms $id]] 1 }
}
proc mentions {pattern ownWhere} {
    global haystack
    set phrase [phrase $pattern]
    if {[llength $phrase] < 2} { return {} }
    set found {}
    foreach entry $haystack {
        lassign $entry file line text
        if {[string first $phrase $text] < 0} { continue }
        if {"$file:$line" eq $ownWhere} { continue }
        if {![regexp {Claim|Wish|Hold!|Say|Assert!|claims|wishes} $text]} { continue }
        if {[regexp {When|Query|Require!|ForEach!|Expect!|collected results} $text]} { continue }
        lappend found "$file:$line"
    }
    return $found
}

set fd [open $out/unmatched.tsv w]
puts $fd "where\tkind\tclass\tpattern\tpossible_producers_elsewhere"
set unmatched 0
set unmatchedClasses {}
for {set c 0} {$c < [llength $consumers]} {incr c} {
    if {[llength [dict get $consumerHits $c]]} { continue }
    if {[dict exists $genericConsumers $c]} { continue }
    lassign [lindex $consumers $c] id scope kind pattern
    if {[llength $pattern] == 0} { continue }
    set form [lindex $forms $id]
    set found [mentions $pattern [where $form]]
    # What is being asked for decides how to read "nothing matches".
    if {[lindex $pattern 0] eq {lit when}} {
        set class "rule-on-rules"
    } elseif {[lindex $pattern 1] eq {lit wishes}} {
        set class "wish-api"
    } else {
        set class "claim"
    }
    if {[llength $found]} { append class "+text" }
    count unmatchedClasses $class
    puts $fd "[where $form]\t$kind\t$class\t[clauseText $pattern]\t[lrange $found 0 4]"
    incr unmatched
}
close $fd

set fd [open $out/unhandled.tsv w]
puts $fd "where\twish"
set unhandled 0
set wishCount 0
set wishSampledOnly 0
set polled {}
for {set e 0} {$e < [llength $emissions]} {incr e} {
    lassign [lindex $emissions $e] id scope kind terms
    if {[lindex $terms 1] ne {lit wishes}} { continue }
    if {[dict exists $genericEmissions $e]} { continue }
    incr wishCount
    set reactive 0
    set sampled 0
    foreach c [dict get $emissionHits $e] {
        if {[lindex $consumers $c 2] in {when collected}} {
            set reactive 1
        } else {
            set sampled 1
        }
    }
    if {!$reactive && $sampled} {
        incr wishSampledOnly
        lappend polled "[emissionWhere [lindex $emissions $e]]\t[clauseText [lrange $terms 2 end]]"
    }
    if {!$reactive && !$sampled} {
        puts $fd "[emissionWhere [lindex $emissions $e]]\t[clauseText [lrange $terms 2 end]]"
        incr unhandled
    }
}
close $fd
set fd [open $out/polled.tsv w]
puts $fd "where\twish"
puts $fd [join $polled "\n"]
close $fd

set fd [open $out/generic.tsv w]
puts $fd "where\trole\tform"
dict for {c _} $genericConsumers {
    lassign [lindex $consumers $c] id scope kind pattern
    if {[llength $pattern] == 0} { continue }
    puts $fd "[where [lindex $forms $id]]\tpattern ($kind)\t[clauseText $pattern]"
}
dict for {e _} $genericEmissions {
    lassign [lindex $emissions $e] id scope kind terms
    if {$kind eq "rule"} { continue }
    puts $fd "[emissionWhere [lindex $emissions $e]]\tstatement ($kind)\t[clauseText $terms]"
}
close $fd

# ---- Rule graph ----

# Node -1:<file> is a program's top level; other nodes are rule form ids.
proc nodeOf {scope formId} {
    global forms
    if {$scope >= 0} { return $scope }
    return "top:[dict get [lindex $forms $formId] file]"
}
proc nodeFile {node} {
    global forms
    if {[string match top:* $node]} { return [string range $node 4 end] }
    return [dict get [lindex $forms $node] file]
}

# edges: dict "from to" -> list of statement skeletons carried
set ruleEdges [dict create]
set programEdges [dict create]
for {set e 0} {$e < [llength $emissions]} {incr e} {
    lassign [lindex $emissions $e] eid escope ekind terms
    if {$eid <= $externalBase} {
        set from "ext:[lindex $externals [expr {$externalBase - $eid}] 0]"
        set fromFile $from
    } else {
        set from [nodeOf $escope $eid]
        set fromFile [nodeFile $from]
    }
    if {$ekind eq "rule"} { continue }
    foreach c [dict get $emissionHits $e] {
        lassign [lindex $consumers $c] cid cscope ckind pattern
        set to [nodeOf $cscope $cid]
        set toFile [nodeFile $to]
        dict lappend ruleEdges [list $from $to] [list $ckind [skeleton $terms]]
        dict lappend programEdges [list $fromFile $toFile] [skeleton $terms]
    }
}

# Tarjan's strongly connected components over the rule graph.
set succ [dict create]
dict for {edge labels} $ruleEdges {
    lassign $edge from to
    set isQuery 1
    foreach label $labels {
        if {[lindex $label 0] ne "query"} { set isQuery 0 }
    }
    # A rule that only samples a statement with Query! does not re-run
    # when it changes, so it cannot be part of a reactive cycle.
    if {$isQuery} { continue }
    dict lappend succ $from $to
    if {![dict exists $succ $to]} { dict set succ $to {} }
}

set tIndex 0
set tStack {}
set tIdx [dict create]
set tLow [dict create]
set tOn [dict create]
set sccs {}
proc strongconnect {v} {
    global succ tIndex tStack tIdx tLow tOn sccs
    dict set tIdx $v $tIndex
    dict set tLow $v $tIndex
    incr tIndex
    lappend tStack $v
    dict set tOn $v 1
    foreach w [dict get $succ $v] {
        if {![dict exists $tIdx $w]} {
            strongconnect $w
            if {[dict get $tLow $w] < [dict get $tLow $v]} {
                dict set tLow $v [dict get $tLow $w]
            }
        } elseif {[dict exists $tOn $w]} {
            if {[dict get $tIdx $w] < [dict get $tLow $v]} {
                dict set tLow $v [dict get $tIdx $w]
            }
        }
    }
    if {[dict get $tLow $v] == [dict get $tIdx $v]} {
        set component {}
        while {1} {
            set w [lindex $tStack end]
            set tStack [lrange $tStack 0 end-1]
            dict unset tOn $w
            lappend component $w
            if {$w eq $v} { break }
        }
        lappend sccs $component
    }
}
foreach v [dict keys $succ] {
    if {![dict exists $tIdx $v]} { strongconnect $v }
}

proc nodeText {node} {
    global forms
    if {[string match top:* $node]} { return "[string range $node 4 end] (top level)" }
    if {[string match ext:* $node]} { return $node }
    set form [lindex $forms $node]
    return "[where $form]  [dict get $form cmd] [join [lmap c [dict get $form clauses] { clauseText $c }] { & }]"
}

set fd [open $out/cycles.txt w]
puts $fd "# Rule cycles: sets of rules whose emitted statements can match each"
puts $fd "# other's patterns. Each is a candidate for self-supporting statements"
puts $fd "# (a derived statement that keeps itself alive). Holes match anything,"
puts $fd "# so check the values before concluding a cycle is real."
puts $fd ""
set cycleCount 0
set selfLoops 0
foreach component $sccs {
    if {[llength $component] > 1} {
        incr cycleCount
        puts $fd "cycle of [llength $component] rules:"
        foreach node $component { puts $fd "  [nodeText $node]" }
        puts $fd ""
    } else {
        set v [lindex $component 0]
        if {$v in [dict get $succ $v]} {
            incr selfLoops
            puts $fd "self-loop:"
            puts $fd "  [nodeText $v]"
            foreach label [dict get $ruleEdges [list $v $v]] {
                puts $fd "    via  [lindex $label 1]"
            }
            puts $fd ""
        }
    }
}

# A rule with a negated clause whose own body (or a rule nested in it) can
# emit something the negated pattern matches: it removes its own premise.
# With Hold! the statement outlives the match, so the rule runs once and
# stays quiet ("default unless someone says otherwise"). With Claim or Wish
# the statement goes away with the match, the premise becomes true again,
# and the rule oscillates.
puts $fd "# Rules that can emit what they negate:"
puts $fd "#   Hold!        -> settles (the default-value idiom)"
puts $fd "#   Claim / Wish -> oscillates if the values really coincide"
puts $fd ""
set negLoops 0
set negHolds 0
proc enclosedBy {id ancestor} {
    global forms
    while {$id >= 0} {
        if {$id == $ancestor} { return 1 }
        set id [dict get [lindex $forms $id] parent]
    }
    return 0
}
for {set c 0} {$c < [llength $consumers]} {incr c} {
    lassign [lindex $consumers $c] cid cscope ckind pattern
    if {$ckind ne "collected"} { continue }
    set form [lindex $forms $cid]
    set negated 0
    foreach clause [dict get $form clauses] {
        if {[hasNeg $clause]} { set negated 1 }
    }
    if {!$negated} { continue }
    foreach e [dict get $consumerHits $c] {
        lassign [lindex $emissions $e] eid escope ekind terms
        if {$eid < 0 || $ekind eq "rule"} { continue }
        if {[enclosedBy $eid $cid]} {
            if {$ekind eq "hold"} {
                incr negHolds
                set verdict "settles (Hold!)"
            } else {
                incr negLoops
                set verdict "oscillation candidate ([dict get [lindex $forms $eid] cmd])"
            }
            puts $fd "$verdict"
            puts $fd "  [where $form]  When [join [lmap cl [dict get $form clauses] { clauseText $cl }] { & }]"
            puts $fd "  emits at [where [lindex $forms $eid]]:  [clauseText $terms]"
            puts $fd ""
        }
    }
}
close $fd

# ---- Output: graphs ----

proc dotQuote {text} {
    return "\"[string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n"] $text]\""
}

# Program graph.
set fd [open $out/programs.dot w]
puts $fd "digraph programs {"
puts $fd "  rankdir=LR; node \[shape=box, fontname=\"Helvetica\", fontsize=10\];"
puts $fd "  edge \[fontname=\"Helvetica\", fontsize=8, color=\"#55555588\"\];"
set programNodes [dict create]
dict for {edge labels} $programEdges {
    lassign $edge from to
    dict set programNodes $from 1
    dict set programNodes $to 1
}
proc shortName {file} {
    regsub {^builtin-programs/} $file {} file
    regsub {\.folk$} $file {} file
    return $file
}
dict for {node _} $programNodes {
    set attrs "label=[dotQuote [shortName $node]]"
    if {[string match ext:* $node]} { append attrs ", style=dashed" }
    puts $fd "  [dotQuote $node] \[$attrs\];"
}
set programEdgeCount 0
dict for {edge labels} $programEdges {
    lassign $edge from to
    if {$from eq $to} { continue }
    incr programEdgeCount
    set shapes [lsort -unique $labels]
    set width [expr {1 + log([llength $shapes]) / log(2)}]
    puts $fd "  [dotQuote $from] -> [dotQuote $to] \[penwidth=[format %.1f $width], tooltip=[dotQuote [join [lrange $shapes 0 9] "\n"]]\];"
}
puts $fd "}"
close $fd

# Rule graph, clustered by program.
set fd [open $out/rules.dot w]
puts $fd "digraph rules {"
puts $fd "  rankdir=LR; compound=true; node \[shape=box, fontname=\"Helvetica\", fontsize=9\];"
puts $fd "  edge \[color=\"#55555588\"\];"
set byFile [dict create]
set ruleNodes [dict create]
dict for {edge labels} $ruleEdges {
    lassign $edge from to
    dict set ruleNodes $from 1
    dict set ruleNodes $to 1
}
dict for {node _} $ruleNodes {
    if {[string match ext:* $node]} {
        dict lappend byFile $node $node
    } else {
        dict lappend byFile [nodeFile $node] $node
    }
}
set cluster 0
dict for {file nodes} $byFile {
    puts $fd "  subgraph cluster_$cluster {"
    puts $fd "    label=[dotQuote [shortName $file]]; fontname=\"Helvetica\"; fontsize=10; color=\"#999999\";"
    foreach node $nodes {
        if {[string match top:* $node]} {
            set label "(top level)"
        } elseif {[string match ext:* $node]} {
            set label $node
        } else {
            set form [lindex $forms $node]
            set label "[dict get $form line]: [join [lmap c [dict get $form clauses] { clauseText $c }] "\n& "]"
        }
        puts $fd "    [dotQuote $node] \[label=[dotQuote $label]\];"
    }
    puts $fd "  }"
    incr cluster
}
dict for {edge labels} $ruleEdges {
    lassign $edge from to
    set style ""
    set onlyQuery 1
    foreach label $labels {
        if {[lindex $label 0] ne "query"} { set onlyQuery 0 }
    }
    if {$onlyQuery} { set style ", style=dashed" }
    puts $fd "  [dotQuote $from] -> [dotQuote $to] \[tooltip=[dotQuote [lindex $labels 0 1]]$style\];"
}
puts $fd "}"
close $fd

# ---- Output: statements that fire a rest-variable rule without matching ----

# When a statement is added, folk.c looks for rules by querying the trie
# for `when <statement> /__lambda/ with environment /__env/`. A stored
# rule `when P1 .. Pk /...rest/ <body> with environment <env>` is found by
# that query not only when the statement continues past Pk, but also when
# the statement is short enough for the query's own tail to run into the
# rest variable (trieLookupImpl returns everything below a stored rest
# variable without looking further):
#   statement has k-1 terms: /__lambda/ lines up with Pk, `with` with rest
#   statement has k-2 terms: additionally needs Pk to be `with` or a variable
# clauseUnify then accepts the pair because it only compares the terms both
# sides have, and the body runs with the rest variable unbound.
proc prefixFires {p s} {
    set k [expr {[llength $p] - 1}]
    if {$k < 1 || [lindex $p $k 0] ne "rest"} { return 0 }
    set n [llength $s]
    foreach term $s {
        if {[lindex $term 0] in {splat rest}} { return 0 }
    }
    if {$n == $k - 1} {
        return [unifies [lrange $p 0 $k-2] $s]
    }
    if {$n == $k - 2 && $n > 0} {
        lassign [lindex $p $k-1] type value
        if {($type eq "lit" && $value eq "with") || $type in {var wild}} {
            return [unifies [lrange $p 0 $k-3] $s]
        }
    }
    return 0
}
set fd [open $out/prefix-fires.tsv w]
puts $fd "statement_at\tstatement\trule_at\trule_pattern"
set prefixPairs 0
set prefixRules [dict create]
for {set c 0} {$c < [llength $consumers]} {incr c} {
    lassign [lindex $consumers $c] cid cscope ckind pattern
    if {$ckind ne "when"} { continue }
    if {[lindex $pattern end 0] ne "rest"} { continue }
    for {set e 0} {$e < [llength $emissions]} {incr e} {
        lassign [lindex $emissions $e] eid escope ekind terms
        if {$ekind eq "rule" || [dict exists $genericEmissions $e]} { continue }
        set hit [prefixFires $pattern $terms]
        if {!$hit && [lindex $terms 1] eq {lit claims}} {
            set hit [prefixFires $pattern [lrange $terms 2 end]]
        }
        if {$hit} {
            incr prefixPairs
            dict set prefixRules $cid 1
            puts $fd "[emissionWhere [lindex $emissions $e]]\t[clauseText $terms]\t[where [lindex $forms $cid]]\t[clauseText $pattern]"
        }
    }
}
close $fd

# ---- Output: interfaces ----

# Folk programs do not import each other; they meet on statement shapes.
# For every shape, who can emit it and who reads it.
set shapeProducers [dict create]
set shapeConsumers [dict create]
for {set e 0} {$e < [llength $emissions]} {incr e} {
    lassign [lindex $emissions $e] eid escope ekind terms
    if {$ekind eq "rule" || [dict exists $genericEmissions $e]} { continue }
    set shape [skeleton $terms]
    if {$eid <= $externalBase} {
        set file [lindex $externals [expr {$externalBase - $eid}] 0]
    } else {
        set file [dict get [lindex $forms $eid] file]
    }
    if {![dict exists $shapeProducers $shape] ||
        $file ni [dict get $shapeProducers $shape]} {
        dict lappend shapeProducers $shape $file
    }
    foreach c [dict get $emissionHits $e] {
        set cfile [dict get [lindex $forms [lindex $consumers $c 0]] file]
        if {![dict exists $shapeConsumers $shape] ||
            $cfile ni [dict get $shapeConsumers $shape]} {
            dict lappend shapeConsumers $shape $cfile
        }
    }
}
set rows {}
dict for {shape producers} $shapeProducers {
    set readers [expr {[dict exists $shapeConsumers $shape] ? [dict get $shapeConsumers $shape] : {}}]
    lappend rows [list [expr {[llength $producers] + [llength $readers]}] \
                      $shape $producers $readers]
}
set fd [open $out/interfaces.tsv w]
puts $fd "producers\treaders\tstatement_shape\tproducer_files\treader_files"
foreach row [lsort -decreasing -integer -index 0 $rows] {
    lassign $row _ shape producers readers
    puts $fd "[llength $producers]\t[llength $readers]\t$shape\t[lmap f $producers { shortName $f }]\t[lmap f $readers { shortName $f }]"
}
close $fd

# ---- Output: subsystem graph ----

# The program graph folded by directory, small enough to read.
proc subsystem {file} {
    if {[string match ext:* $file]} { return "C runtime" }
    set parts [split $file /]
    if {[lindex $parts 0] eq "builtin-programs" && [llength $parts] == 3} {
        return [lindex $parts 1]
    }
    if {[lindex $parts 0] eq "user-programs"} { return "user-programs" }
    return [shortName $file]
}
set subsystemEdges [dict create]
set subsystemNodes [dict create]
dict for {edge labels} $programEdges {
    lassign $edge from to
    set a [subsystem $from]; set b [subsystem $to]
    dict set subsystemNodes $a 1
    dict set subsystemNodes $b 1
    if {$a eq $b} { continue }
    foreach label $labels {
        if {![dict exists $subsystemEdges [list $a $b]] ||
            $label ni [dict get $subsystemEdges [list $a $b]]} {
            dict lappend subsystemEdges [list $a $b] $label
        }
    }
}
set fd [open $out/subsystems.dot w]
puts $fd "digraph subsystems {"
puts $fd "  rankdir=LR; node \[shape=box, style=rounded, fontname=\"Helvetica\", fontsize=11\];"
puts $fd "  edge \[fontname=\"Helvetica\", fontsize=8, color=\"#444444\"\];"
dict for {node _} $subsystemNodes {
    puts $fd "  [dotQuote $node];"
}
dict for {edge shapes} $subsystemEdges {
    lassign $edge a b
    set n [llength $shapes]
    if {$n < 2} { continue }
    puts $fd "  [dotQuote $a] -> [dotQuote $b] \[label=\"$n\", penwidth=[format %.1f [expr {0.6 + log($n)}]], tooltip=[dotQuote [join [lrange $shapes 0 14] "\n"]]\];"
}
puts $fd "}"
close $fd

# ---- Output: undefined commands ----

# Commands called by literal name that are neither built in (the list in
# builtin-commands.txt comes from [info commands] in a booted Folk) nor
# defined by a proc or fn anywhere in the tree.
set known [dict create]
foreach name [split [readFile $here/builtin-commands.txt] "\n"] {
    dict set known $name 1
    dict set known [string trimleft $name :] 1
}
foreach definition [ff::definitions] {
    set name [lindex $definition 0]
    dict set known $name 1
    dict set known [string trimleft $name :] 1
    dict set known [namespace tail $name] 1
}
# procs in vendored and library Tcl that programs load on demand
foreach path [concat [glob -nocomplain $root/vendor/*.tcl] \
                  [glob -nocomplain $root/vendor/*/*.tcl] \
                  [glob -nocomplain $root/lib/*.tcl] $root/prelude.tcl] {
    foreach line [split [readFile $path] "\n"] {
        if {[regexp {^\s*(?:local\s+)?proc\s+([^\s]+)} $line -> name] ||
            [regexp {^\s*(?:namespace eval|class)\s+([^\s]+)} $line -> name]} {
            dict set known $name 1
            dict set known [string trimleft $name :] 1
            dict set known [namespace tail $name] 1
        }
    }
}
set fd [open $out/undefined-commands.tsv w]
puts $fd "command\tcalls\tfirst_sites"
set undefined [dict create]
foreach site [ff::callSites] {
    lassign $site name file line
    if {[dict exists $isTest $file]} { continue }
    if {[dict exists $known $name] || [dict exists $known [string trimleft $name :]]} { continue }
    # Only plain identifiers: anything else is data, C or a sub-language.
    if {![regexp {^[A-Za-z_][A-Za-z0-9_:!]*$} $name]} { continue }
    if {[string first "::" $name] >= 0} { continue }
    dict lappend undefined $name "$file:$line"
}
set undefinedCount 0
foreach name [lsort [dict keys $undefined]] {
    set sites [dict get $undefined $name]
    puts $fd "$name\t[llength $sites]\t[lrange $sites 0 3]"
    incr undefinedCount
}
close $fd

# ---- Output: capture analysis ----

# For every rule body: which variables its creation captures (everything
# visible where the When is written) against which of those the body can
# read (its free variables, and those of the rules nested in it, and of
# the fns it calls).
set scopes [ff::scopes]
proc scopeGet {key what} {
    global scopes
    if {[dict exists $scopes $key]} { return [dict get $scopes $key $what] }
    return {}
}
proc scopeKeyOf {id file} {
    expr {$id < 0 ? "top:$file" : $id}
}
# children: scope key -> child form ids that are themselves scopes
set children [dict create]
foreach form $forms {
    set id [dict get $form id]
    if {![dict get $form body] && [dict get $form kind] ne "fn"} { continue }
    if {[dict get $form kind] in {query}} { continue }
    dict lappend children [scopeKeyOf [dict get $form parent] [dict get $form file]] $id
}

# Variables visible inside scope $key: its own bindings plus, unless it is
# a proc (a fresh Tcl scope), everything visible where it was created.
set visibleMemo [dict create]
proc visible {key} {
    global forms visibleMemo
    if {[dict exists $visibleMemo $key]} { return [dict get $visibleMemo $key] }
    set names [scopeGet $key binds]
    if {![string match top:* $key]} {
        set form [lindex $forms $key]
        if {[dict get $form kind] ne "proc"} {
            set parentKey [scopeKeyOf [dict get $form parent] [dict get $form file]]
            foreach name [visible $parentKey] {
                if {$name ni $names} { lappend names $name }
            }
        }
    }
    dict set visibleMemo $key $names
    return $names
}

# Variables scope $key reads from outside itself.
set freeMemo [dict create]
proc free {key} {
    global forms children freeMemo
    if {[dict exists $freeMemo $key]} { return [dict get $freeMemo $key] }
    dict set freeMemo $key {}
    set reads [scopeGet $key reads]
    # A call to a fn reads its ^name variable (prelude.tcl's `unknown`
    # finds it in the environment).
    foreach name [scopeGet $key calls] {
        if {"^$name" ni $reads} { lappend reads "^$name" }
    }
    if {[dict exists $children $key]} {
        foreach child [dict get $children $key] {
            foreach name [free $child] {
                if {$name ni $reads} { lappend reads $name }
            }
        }
    }
    set binds [scopeGet $key binds]
    set result {}
    foreach name $reads {
        if {$name ni $binds} { lappend result $name }
    }
    dict set freeMemo $key $result
    return $result
}

set fd [open $out/capture.tsv w]
puts $fd "where\tkind\tcaptured\tused\tunused\tunused_names"
set capSites 0; set capTotal 0; set capUsed 0; set capFnUnused 0
foreach form $forms {
    if {![inSystem $form]} { continue }
    set kind [dict get $form kind]
    if {$kind ni {when subscribe unmatch handler} &&
        !($kind eq "hold" && [dict get $form body])} { continue }
    if {![dict get $form body]} { continue }
    set opts [dict get $form opts]
    if {[dict exists $opts -noncapturing]} { continue }
    # Skip rules written inside a proc: what they capture depends on the
    # caller.
    set p [dict get $form parent]; set inProc 0
    while {$p >= 0} {
        if {[dict get [lindex $forms $p] kind] eq "proc"} { set inProc 1 }
        set p [dict get [lindex $forms $p] parent]
    }
    if {$inProc} { continue }

    set id [dict get $form id]
    set parentKey [scopeKeyOf [dict get $form parent] [dict get $form file]]
    set captured [visible $parentKey]
    set needed [free $id]
    set used {}; set unused {}
    foreach name $captured {
        if {$name in $needed} { lappend used $name } else { lappend unused $name }
    }
    # A fn that is needed brings its own free variables with it; without
    # walking fn bodies per call site we cannot tell which, so count a
    # captured ^fn as used only if called.
    incr capSites
    incr capTotal [llength $captured]
    incr capUsed [llength $used]
    foreach name $unused {
        if {[string index $name 0] eq "^"} { incr capFnUnused }
    }
    puts $fd "[where $form]\t$kind\t[llength $captured]\t[llength $used]\t[llength $unused]\t$unused"
}
close $fd

# ---- Summary ----

set m [open $out/metrics.txt a]
puts $m ""
puts $m "Diagnostics"
foreach pair [topN $diagCounts 100] {
    lassign $pair n code
    puts $m [format "  %-14s %5d" $code $n]
}
puts $m ""
puts $m "Rule graph (system programs)"
puts $m "  emitted statement shapes         [llength $emissions]  ([llength $externals] from C / prelude)"
puts $m "  patterns matched against the db  [llength $consumers]"
puts $m "  patterns nothing can match       $unmatched   (unmatched.tsv)"
foreach pair [topN $unmatchedClasses 10] {
    lassign $pair n class
    puts $m [format "      %-22s %4d" $class $n]
}
puts $m "  wishes                           $wishCount"
puts $m "  wishes only read by Query!       $wishSampledOnly   (polled, not reacted to)"
puts $m "  wishes nothing reads             $unhandled   (unhandled.tsv)"
puts $m "  rule-to-rule edges               [dict size $ruleEdges]"
puts $m "  program-to-program edges         $programEdgeCount"
puts $m "  rule cycles (2+ rules)           $cycleCount   (cycles.txt)"
puts $m "  rules that feed themselves       $selfLoops"
puts $m "  negate-then-Hold! (default idiom) $negHolds"
puts $m "  negate-then-Claim/Wish candidates $negLoops"
puts $m "  Notify: sites / Subscribe: sites [llength $notifies] / [llength $subscribes]"
puts $m "  distinct statement shapes         [dict size $shapeProducers]   (interfaces.tsv)"
puts $m "  statement/rule pairs where a short statement fires a /...rest/ rule"
puts $m "    without matching it            $prefixPairs pairs, [dict size $prefixRules] rules   (prefix-fires.tsv)"
puts $m "  command names with no definition $undefinedCount   (undefined-commands.tsv, needs review)"
puts $m ""
puts $m "Environment capture (rule bodies outside procs, system programs)"
puts $m "  capturing sites                  $capSites"
if {$capSites > 0} {
    puts $m [format "  variables captured per site      %.1f mean  (%d total)" [expr {double($capTotal) / $capSites}] $capTotal]
    puts $m [format "  of those, read by the body       %.1f mean  (%d total)" [expr {double($capUsed) / $capSites}] $capUsed]
    puts $m [format "  captured but never read          %d (%.0f%%), of which %d are fn bodies" [expr {$capTotal - $capUsed}] [expr {100.0 * ($capTotal - $capUsed) / $capTotal}] $capFnUnused]
}
close $m
puts stderr "wrote $out"
