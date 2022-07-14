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
proc runWhen {clause cb enclosingMatchStack match} {
    set ::currentMatchStack [dict merge $enclosingMatchStack $match]
    dict with ::currentMatchStack $cb
}
proc evaluate {} {
    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        lassign [lindex $::whens $i] clause cb enclosingMatchStack
        dict for {stmt _} $::statements {
            set match [matches $clause $stmt]
            if {$match == false} { set match [matches [list /someone/ claims {*}$clause] $stmt] }

            if {$match != false} { runWhen $clause $cb $enclosingMatchStack $match }
        }

        # i have a when
        # i want to walk every token in the when and use it to walk the statement trie
        # when /someone/ claims /page/ has program code /code/
        puts "clause: $clause"
        set tries [list $::statementsTrie]
        foreach word $clause {
            puts "tries: $tries"
            set nextTries [list]
            foreach trie $tries {
                puts "trie: $trie"
                dict for {key subtrie} $trie {
                    puts "  compare key $key = word $word"
                    if {[regexp {^/([^/]+)/$} $word -> clauseVarName]} {
                        lappend nextTries $subtrie
                    } elseif {$key == $word} {
                        lappend nextTries $subtrie
                    }
                }
            }
            set tries $nextTries
        }
        puts "FINAL: $tries"
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
    When /someone/ claims /name/ is a /animal/ {
        puts "found an animal $name"
    }
    Claim Bob is a cat
}

# $ tclsh useful/minimal-system.tcl
# found an animal George
# found an animal Bob
