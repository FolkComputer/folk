
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
        foreach localName $localNames {
            dict set locals $localName [set $localName]
        }
        set locals
    }]
    set when [list WHEN $clause $cb [dict merge $::currentMatchStack $locals]]

    lappend ::whens $when
}

proc runWhen {clause cb enclosingMatchStack match} {
    set ::currentMatchStack [dict merge $enclosingMatchStack $match]
    dict with ::currentMatchStack $cb
}

proc matches {clause statement} {
    set match [dict create]

    for {set i 0} {$i < [llength $clause]} {incr i} {
        set clauseWord [lindex $clause $i]
        set statementWord [lindex $statement $i]
        if {[string index $clauseWord 0] eq "/"} {
            set clauseVarName [string range $clauseWord 1 [expr [string length $clauseWord] - 2]]
            set clauseVarValue $statementWord
            dict set match $clauseVarName $clauseVarValue

        } elseif {$clauseWord != $statementWord} {
            return false
        }
    }
    return $match
}

proc evaluate {} {
    # TODO: implement incremental evaluation
    # there must be a function frame' that is in terms of diffs ...
    # Claim should add a +1 diff to an append-only log ...
    # then the evaluator can reduce over the log ...

    for {set i 0} {$i <= [llength $::whens]} {incr i} {
        set when [lindex $::whens $i]
        set clause [lindex $when 1]
        set cb [lindex $when 2]
        set enclosingMatchStack [lindex $when 3]

        # i have a when
        # i want to walk every token in the when and use it to walk the statement trie

        # when /someone/ claims /page/ has program code /code/
        # set tries [list $::statementsTrie]
        # foreach word $clause {
        #     set nextTries [list]
        #     foreach trie $nextTries {
        #         dict for {key subtrie} $trie {
        #             if {$key == $word} {
        #                 lappend nextTries $subtrie
        #             }
        #         }
        #     }
        #     set tries $nextTries
        # }

        dict for {statement _} $::statements {
            set match [matches $clause $statement]
            if {$match == false} {
                set match [matches [list /someone/ claims {*}$clause] $statement]
            }
            if {$match != false} {
                runWhen $clause $cb $enclosingMatchStack $match
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

    uplevel 1 $cb

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
