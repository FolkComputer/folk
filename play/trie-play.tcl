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
    set locals [uplevel 1 { # get local variables & serialize them (to fake lexical scope)
        set localNames [info locals]
        set locals [dict create]
        foreach localName $localNames { dict set locals $localName [set $localName] }
        set locals
    }]
    lappend ::whens [list $clause $cb [dict merge $::currentMatchStack $locals]]
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
        dict with ::currentMatchStack $cb
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
proc Step {cb} {
    # clear the statement set
    set ::statements [dict create]
    set ::statementsTrie [dict create]
    set ::whens [list]
    set ::currentMatchStack [dict create]
    uplevel 1 $cb ;# run the body code

    while 1 {
        set prevStatements $::statements
        evaluate
        if {$::statements eq $prevStatements} break ;# fixpoint
    }
}

Step {
    Claim George is a dog
    When /name/ is a /animal/ {
        puts "found an animal $name"
    }
    Claim Bob is a cat
}

# $ tclsh useful/minimal-system.tcl
# found an animal George
# found an animal Bob
