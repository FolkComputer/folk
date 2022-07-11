catch {
    package require starkit
    starkit::startup
}

proc Claim {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone claims {*}$args] true
}
proc Wish {args} {
    # TODO: get the caller instead of `someone`
    dict set ::statements [list someone wishes {*}$args] true
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
        set clause [lindex $when 0]
        set cb [lindex $when 1]
        set enclosingMatchStack [lindex $when 2]
        # TODO: use a trie or regexes or something
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

# with key1 /value1/ key2 /value2/
# With all /matches/
# To know when

set ::alwaysCbs [list]
proc Always {cb} {
    lappend ::alwaysCbs $cb
}
proc Step {cb} {
    # clear the statement set
    set ::statements [dict merge {*}[dict values $::assertedStatementsFrom]]
    set ::whens [list]

    set ::currentMatchStack [dict create]

    foreach alwaysCb $::alwaysCbs {uplevel 1 $alwaysCb}
    uplevel 1 $cb

    # event: an incoming statement bundle
    # a statement bundle includes statements and statement-retractions
    # do peers need to connect? or is it like a message thing?
    # there needs to be a persistent statement database?

    while 1 {
        set prevStatements $::statements
        evaluate
        if {$::statements eq $prevStatements} break ;# fixpoint
    }

    # is there an effect set that comes out of the frame?

    # puts $::statements

    # stream effects/output statement set outward?
    # (for now, draw all the graphics requests)
    Display::commit
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
