# difftest.tcl -- differential test of tclparse.tcl against Jim's tokenizer.
#
# Usage: jimsh difftest.tcl FILE...
#
# For each file, parses the text with tp::parse and with the oracle (Jim's
# own JimParseScript), and compares commands, words and word parts. Then it
# does the same for the contents of every braced word, recursively, so the
# parsers are also compared on text that is not Tcl at all (C, GLSL, HTML).
# Exits non-zero if the two ever disagree.

set here [file dirname [info script]]
source $here/tclparse.tcl
set oracle $here/oracle

# Runs the oracle on $text; returns commands in tp::parse's shape.
proc oracleParse {text} {
    set tmp [file tempfile /tmp/difftest_XXXXXX]
    set fd [open $tmp w]
    puts -nonewline $fd $text
    close $fd
    set out [exec $::oracle $tmp]
    file delete $tmp

    set commands {}
    set haveCommand 0
    set haveWord 0
    foreach record [split $out "\n"] {
        set fields [split $record "\t"]
        switch [lindex $fields 0] {
            C {
                if {$haveWord} { lappend words $word; set haveWord 0 }
                if {$haveCommand} {
                    lappend commands [dict create line $line words $words]
                }
                set haveCommand 1
                set line [lindex $fields 1]
                set words {}
            }
            W {
                if {$haveWord} { lappend words $word }
                set haveWord 1
                set word [dict create expand [lindex $fields 1] parts {}]
            }
            T {
                lassign $fields _ type tline hex
                if {![dict exists $word line]} { dict set word line $tline }
                if {$type eq "cmd"} {
                    dict lappend word parts [list $type [binary format H* $hex] $tline]
                } else {
                    dict lappend word parts [list $type [binary format H* $hex]]
                }
            }
        }
    }
    if {$haveWord} { lappend words $word }
    if {$haveCommand} {
        lappend commands [dict create line $line words $words]
    }
    return $commands
}

# Jim splits plain text into several esc tokens around parentheses and
# emits empty ones at quote boundaries. Merge neighbours and drop the empty
# ones so that only real differences remain.
proc normalize {parts} {
    set out {}
    foreach part $parts {
        lassign $part type text
        if {$type eq "esc" && [llength $out] &&
            [lindex $out end 0] eq "esc"} {
            lset out end 1 "[lindex $out end 1]$text"
        } else {
            lappend out $part
        }
    }
    if {[llength $out] > 1} {
        set out [lmap part $out {
            if {$part eq {esc {}}} { continue }
            set part
        }]
    }
    return $out
}

set stats [dict create scripts 0 commands 0 words 0 mismatches 0]

proc compare {what text depth} {
    global stats
    set mine [tp::parse $text]
    set theirs [oracleParse $text]
    dict incr stats scripts

    if {[llength $mine] != [llength $theirs]} {
        puts "MISMATCH $what: [llength $mine] commands vs [llength $theirs]"
        dict incr stats mismatches
        return
    }
    set braced {}
    foreach a $mine b $theirs {
        dict incr stats commands
        set where "$what line [dict get $b line]"
        if {[dict get $a line] != [dict get $b line]} {
            puts "MISMATCH $where: command line [dict get $a line]"
            dict incr stats mismatches
        }
        set aw [dict get $a words]; set bw [dict get $b words]
        if {[llength $aw] != [llength $bw]} {
            puts "MISMATCH $where: [llength $aw] words vs [llength $bw]"
            dict incr stats mismatches
            continue
        }
        foreach x $aw y $bw {
            dict incr stats words
            set xp [normalize [dict get $x parts]]
            set yp [normalize [dict get $y parts]]
            if {[dict get $x expand] != [dict get $y expand] || $xp ne $yp} {
                puts "MISMATCH $where:\n  mine:   $xp\n  oracle: $yp"
                dict incr stats mismatches
            } elseif {[dict get $x line] != [dict get $y line]} {
                puts "MISMATCH $where: word line [dict get $x line] vs [dict get $y line]"
                dict incr stats mismatches
            }
            foreach part $xp {
                lassign $part type text
                if {$type eq "str" && [string length $text] > 1} {
                    lappend braced $text
                }
            }
        }
    }
    # tp::parse keeps its state in namespace variables, so recurse only
    # after this level is fully compared.
    foreach text $braced {
        compare "$what>" $text [expr {$depth + 1}]
    }
}

foreach file $argv {
    set fd [open $file r]
    set text [read $fd]
    close $fd
    compare $file $text 0
}
puts "difftest: [dict get $stats scripts] scripts, [dict get $stats commands] commands,\
[dict get $stats words] words, [dict get $stats mismatches] mismatches"
exit [expr {[dict get $stats mismatches] > 0}]
