catch {
    package require starkit
    starkit::startup
}

proc addStatement {s} {
    dict set ::statements $s true
    dict set ::statementsTrie {*}$s LEAF
}

proc Claim {args} {
    # TODO: get the caller instead of `someone`
    addStatement [list someone claims {*}$args]
}
proc Wish {args} {
    # TODO: get the caller instead of `someone`
    addStatement [list someone wishes {*}$args]
}

proc When {args} {
    set clause [lreplace $args end end]
    set cb [lindex $args end]
    
    # get local variables and serialize them
    # (to fake lexical scope)
    set locals [uplevel 1 {
        set localNames [info locals]
        set locals [dict create]
        foreach localName $localNames { dict set locals $localName [set $localName] }
        set locals
    }]
    lappend ::whens [list $clause $cb [dict merge $::currentMatchStack $locals]]
}

set ::assertedStatementsFrom [dict create]
proc Assert {args} {
    set statement $args
    dict set ::assertedStatementsFrom SELF $statement true
}
proc Retract {args} {
    set clause $args
    dict for {origin assertedStatements} $::assertedStatementsFrom {
        dict for {statement _} $assertedStatements {
            set match [matches $clause $statement]
            if {$match != false} {
                dict unset ::assertedStatementsFrom $origin $statement
            }
        }
    }
}

proc matches {clause statement} {
    set match [dict create]

    for {set i 0} {$i < [llength $clause]} {incr i} {
        set clauseWord [lindex $clause $i]
        set statementWord [lindex $statement $i]
        if {[regexp {^/([^/]+)/$} $clauseWord -> clauseVarName]} {
            dict set match $clauseVarName $statementWord
        } elseif {$clauseWord != $statementWord} {
            return false
        }
    }
    return $match
}

proc evaluate {} {
    proc matchWhen {clause} {
        # i have a when
        # i want to walk every token in the when and use it to walk the statement trie
        # when /someone/ claims /page/ has program code /code/
        set paths [list [dict create bindings [dict create] trie $::statementsTrie]]
        foreach word $clause {
            set nextPaths [list]
            foreach path $paths {
                dict with path {
                    dict for {key subtrie} $trie {
                        if {[regexp {^/([^/]+)/$} $word -> clauseVarName]} {
                            set newBindings [dict replace $bindings $clauseVarName $key]
                            lappend nextPaths [dict create bindings $newBindings trie $subtrie]
                        } elseif {$key == $word} {
                            lappend nextPaths [dict create bindings $bindings trie $subtrie]
                        }
                    }
                }
            }
            set paths $nextPaths
        }
        return $paths
    }
    proc runWhen {clause cb enclosingMatchStack match} {
        set ::currentMatchStack [dict merge $enclosingMatchStack $match]
        if {[catch {dict with ::currentMatchStack $cb} err] == 1} { # TCL_ERROR
            puts stderr "error: $err"
        }
    }
    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        lassign [lindex $::whens $i] clause cb enclosingMatchStack

        set paths [matchWhen $clause]
        if {[llength $paths] == 0} { set paths [matchWhen [list /someone/ claims {*}$clause]] }
        foreach path $paths {
            dict with path {
                runWhen $clause $cb $enclosingMatchStack $bindings
            }
        }
    }
}

# pretty-prints latest statement set
proc showStatements {} {
    return [join [lmap statement [dict keys $::statements] {
        lmap word $statement {expr {
            [string length $word] > 20 ?
            "[string range $word 0 20]..." :
            $word
        }}
    }] "\n"]
}
proc showWhens {} {
    return [join [lmap when $::whens {lindex $when 0}] "\n"]
}
proc showStatementsTrie {} {
    proc showStatementsSubtrie {root subtrie} {
        set dot [list]
        foreach key [dict keys $subtrie] {
            if {$root != ""} {
                set shortKey [expr {[string length $key] > 100 ?
                                    "[string range $key 0 50]..." :
                                    $key}]
                lappend dot "\"$root\" -> \"$shortKey\";"
            }
            set value [dict get $subtrie $key]
            if {[lindex $value 0] != "LEAF"} {
                lappend dot [showStatementsSubtrie $key $value]
            }
        }
        return [join $dot "\n"]
    }
    return "digraph { rankdir=LR; [showStatementsSubtrie {} $::statementsTrie] }"
}
proc accept {chan addr port} {
    # (mostly for the Pi)
    # we want to be able to asynchronously receive statements
    set script ""
    while {[gets $chan line] != -1} {
        append script $line\n
        if {[info complete $script]} {
            if {[catch {
                puts $chan [eval $script]; flush $chan
            } ret]} {
                puts $ret
                puts $chan $ret; flush $chan
            }
            set script ""
        }
    }

    close $chan
}
set ::nodename [info hostname]
if {[catch {socket -server accept 4273}]} {
    puts "there's already a Folk node running on this machine"
    set ::nodename "[info hostname]-1"
    socket -server accept 4274
}

set ::alwaysCbs [list]
proc Always {cb} {
    lappend ::alwaysCbs $cb
}
proc StepImpl {cb} {
    # clear the statement set
    set ::statements [dict create]
    set ::statementsTrie [dict create]
    dict for {s _} [dict merge {*}[dict values $::assertedStatementsFrom]] {
        addStatement $s
    }
    set ::whens [list]

    set ::currentMatchStack [dict create]

    foreach alwaysCb $::alwaysCbs {uplevel 1 $alwaysCb}
    uplevel 1 $cb

    while 1 {
        set prevStatements $::statements
        evaluate
        if {$::statements eq $prevStatements} break ;# fixpoint
    }

    Display::commit
}
set ::stepTime "none"
proc Step {cb} {
    set ::stepTime [time {StepImpl $cb}]
}

source "lib/math.tcl"

Always {
    # this defines $this in the contained scopes
    When /this/ has program code /code/ {
        eval $code
    }
}

if {$tcl_platform(os) eq "Darwin"} {
    if {$tcl_version eq 8.5} {
        error "Don't use Tcl 8.5 / macOS system Tcl. Quitting."
    }
    if {[catch {source [file join $::starkit::topdir laptop.tcl]}]} {
        source laptop.tcl
    }
} else {
    source pi/pi.tcl
}

vwait forever
