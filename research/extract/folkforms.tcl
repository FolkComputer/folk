# folkforms.tcl -- recognises Folk forms in a parsed script.
#
# This is the Folk-layer grammar of docs/pl-research.md section 2.2 made
# executable. It walks the commands that tclparse.tcl produces, recognises
# When / Claim / Wish / Hold! / ... the way the procs in prelude.tcl parse
# their arguments, and records one "form" per occurrence. Nothing is
# evaluated, so a word whose value depends on a substitution becomes a
# hole.
#
# A form is a dict:
#   id       index in the list returned by ff::forms
#   kind     when claim wish say hold assert retract subscribe notify
#            unmatch query fn proc
#   cmd      the command word as written (When, QueryOne!, ...)
#   file line
#   parent   id of the enclosing form that has a body, or -1
#   opts     dict of options as written
#   clauses  list of clauses; a clause is a list of terms; a term is
#              {lit value}   literal
#              {var name}    /name/
#              {rest name}   /...name/
#              {wild name}   /someone/ /something/ /anyone/ /anything/ /any/
#              {neg name}    /nobody/ /nothing/
#              {hole src}    value not known statically ($x, [cmd], "a$b")
#              {splat src}   {*}word: unknown number of terms
#   emits    for hold: claim | wish | say | rule | clear
#   body     1 if the form has a script body that was walked
#   diags    list of {code message} grammar or lint diagnostics
#
# ff::walkFile adds a program's forms; ff::forms returns them all.

source [file dirname [info script]]/tclparse.tcl

namespace eval ff {
    variable forms {}
    variable file ""
    # {file char line} for each file left with an open brace/quote/bracket.
    variable parseErrors {}
    # {name file line} for every command whose name is a literal word.
    variable callSites {}
    # {name file line} for every proc / fn definition.
    variable definitions {}
    # > 0 while walking text that was only guessed to be Folk code.
    variable guessing 0
    # {file line commands} for code after an unconditional top-level
    # `return`, which never runs and is not walked.
    variable unreachable {}
    # Scope bookkeeping for the capture analysis. scopes is a dict
    # id -> {binds {names} reads {names} calls {names}}; scope -1 is the
    # top level of the current file and is stored under "top:<file>".
    variable scopes {}

    variable whenFlags {-noncapturing -serially -atomically
                        -atomicallyInherit -nonatomically}
    variable whenValued {-keep -atomicallyWithKey}
    variable sayFlags {-nonatomically}
    variable sayValued {-keep -destructor}
    variable holdFlags {-noncapturing -save}
    variable holdValued {-on -key -keep -source -destructor -version}

    variable nonCapturing {someone something anyone anything any}
    variable negating {nobody nothing}

    variable formNames {When Claim Wish Say Hold! Assert! Retract!
                        Subscribe: Notify: On Query! QueryOne! QuerySimple!
                        Require! Expect! ForEach! fn}
}

proc ff::reset {} {
    variable forms {}
    variable scopes {}
    variable parseErrors {}
    variable callSites {}
    variable definitions {}
    variable unreachable {}
}
proc ff::unreachable {} { variable unreachable; return $unreachable }
proc ff::callSites {} { variable callSites; return $callSites }
proc ff::definitions {} { variable definitions; return $definitions }
proc ff::parseErrors {} { variable parseErrors; return $parseErrors }
proc ff::forms {} { variable forms; return $forms }
proc ff::scopes {} { variable scopes; return $scopes }

proc ff::Add {kind cmd line parent} {
    variable forms; variable file
    set id [llength $forms]
    lappend forms [dict create id $id kind $kind cmd $cmd file $file \
                       line $line parent $parent opts {} clauses {} \
                       body 0 diags {}]
    return $id
}
proc ff::Set {id key value} {
    variable forms
    set form [lindex $forms $id]
    dict set form $key $value
    lset forms $id $form
}
proc ff::Diag {id code message} {
    variable forms
    set form [lindex $forms $id]
    dict lappend form diags [list $code $message]
    lset forms $id $form
}

# ---- Scopes ----

proc ff::ScopeKey {id} {
    variable file
    expr {$id < 0 ? "top:$file" : $id}
}
proc ff::ScopeNote {id what names} {
    variable scopes
    set key [ff::ScopeKey $id]
    if {![dict exists $scopes $key]} {
        dict set scopes $key [dict create binds {} reads {} calls {}]
    }
    set scope [dict get $scopes $key]
    set have [dict get $scope $what]
    foreach name $names {
        if {$name ni $have} { lappend have $name }
    }
    dict set scope $what $have
    dict set scopes $key $scope
}

# ---- Terms ----

# Classifies a term value the way trieScanVariable in trie.c does: a term
# is a variable if it starts and ends with "/", has at least one character
# in between, and contains no space.
proc ff::classify {value} {
    variable nonCapturing; variable negating
    if {[string bytelength $value] >= 3 &&
        [string index $value 0] eq "/" && [string index $value end] eq "/" &&
        [string first " " $value] < 0} {
        set name [string range $value 1 end-1]
        if {[string range $name 0 2] eq "..."} {
            return [list rest [string range $name 3 end]]
        } elseif {$name in $nonCapturing} {
            return [list wild $name]
        } elseif {$name in $negating} {
            return [list neg $name]
        }
        return [list var $name]
    }
    return [list lit $value]
}

proc ff::Term {word} {
    if {[dict get $word expand]} { return [list splat [tp::render $word]] }
    if {![tp::isStatic $word]} { return [list hole [tp::render $word]] }
    return [ff::classify [tp::value $word]]
}

# The static value of a word, or a value no keyword can equal.
proc ff::Value {word} {
    if {$word eq ""} { return "\x01none" }
    if {[tp::isStatic $word]} { return [tp::value $word] }
    return "\x01dynamic"
}

# Splits words into option words and terms.
#   flags    option names that take no value
#   valued   option names that take the following word as their value
#   stopAt   if non-empty, a word after which everything is a term ("--")
# Returns {opts terms positions}; positions lists {option before after} for
# each option: how many clause terms precede and follow it.
proc ff::SplitOptions {words flags valued {stopAt ""}} {
    set opts {}
    set terms {}
    set positions {}
    for {set i 0} {$i < [llength $words]} {incr i} {
        set word [lindex $words $i]
        set value [ff::Value $word]
        if {$stopAt ne "" && $value eq $stopAt} {
            foreach rest [lrange $words $i+1 end] { lappend terms $rest }
            break
        } elseif {$value in $flags} {
            dict set opts $value 1
            lappend positions [list $value [llength $terms]]
        } elseif {$value in $valued} {
            lappend positions [list $value [llength $terms]]
            incr i
            if {$i < [llength $words]} {
                dict set opts $value [tp::render [lindex $words $i]]
            } else {
                dict set opts $value "\x01missing"
            }
        } else {
            lappend terms $word
        }
    }
    set total [llength $terms]
    set positions [lmap position $positions {
        lassign $position option before
        list $option $before [expr {$total - $before}]
    }]
    return [list $opts $terms $positions]
}

# Splits words on a literal "&" into segments.
proc ff::SplitJoin {words} {
    set segments {}
    set current {}
    foreach word $words {
        if {[ff::Value $word] eq "&"} {
            lappend segments $current
            set current {}
        } else {
            lappend current $word
        }
    }
    lappend segments $current
    return $segments
}

# Names a pattern binds in the scope of its body.
proc ff::BoundNames {clauses} {
    set names {}
    foreach clause $clauses {
        foreach term $clause {
            lassign $term type name
            if {$type in {var rest} && $name ni $names} { lappend names $name }
        }
    }
    return $names
}

# Checks shared by every pattern clause.
proc ff::CheckPattern {id clause} {
    set seen {}
    set n [llength $clause]
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $clause $i] type name
        if {$type in {var rest}} {
            if {$name in $seen} {
                ff::Diag $id nonlinear \
                    "variable /$name/ occurs twice in one clause; the\
                     second binding silently wins"
            }
            lappend seen $name
            if {[string bytelength $name] >= 100} {
                ff::Diag $id longvar "variable name is 100 bytes or longer"
            }
            if {[string first "/" $name] >= 0} {
                ff::Diag $id slashvar \
                    "term /$name/ contains a slash but is a variable"
            }
        }
        if {$type eq "rest" && $i != $n - 1} {
            ff::Diag $id midrest \
                "rest variable /...$name/ is not the last term; the clause\
                 can never match"
        }
        if {$type eq "lit" && [string index $name 0] eq "\$"} {
            ff::Diag $id dollarlit \
                "literal term begins with \$ and will be passed to subst"
        }
    }
}

proc ff::CheckDuration {id opts} {
    if {[dict exists $opts -keep]} {
        set keep [dict get $opts -keep]
        if {![regexp {^[0-9]+ms$} $keep] && [string first "\$" $keep] < 0 &&
            [string first "\[" $keep] < 0} {
            ff::Diag $id badkeep "-keep value '$keep' is not <integer>ms"
        }
    }
}

# Options are recognised wherever they appear among the clause terms. After
# the clause is a house style (`Claim ... -destructor {...}`); in the middle
# of one is more likely a term that happens to look like an option.
proc ff::CheckLateOptions {id positions} {
    foreach position $positions {
        lassign $position option before after
        if {$before > 0 && $after > 0} {
            ff::Diag $id midopt \
                "option $option sits between clause terms ($before before,\
                 $after after) and is removed from the clause"
        } elseif {$before > 0} {
            ff::Diag $id trailopt "option $option follows the clause"
        }
    }
}

# ---- Walking ----

proc ff::walkFile {path {name ""}} {
    variable file; variable parseErrors
    set fd [open $path r]
    set text [read $fd]
    close $fd
    set file [expr {$name eq "" ? $path : $name}]
    ff::ScopeNote -1 binds {this}
    set commands [tp::parse $text 1]
    if {[tp::missing] ne ""} {
        lappend parseErrors [list $file {*}[tp::missing]]
    }
    set i 0
    foreach command $commands {
        ff::WalkCommand $command -1
        incr i
        # A program can switch itself off with a bare `return` at top level.
        set words [dict get $command words]
        if {[ff::Value [lindex $words 0]] eq "return" && $i < [llength $commands]} {
            variable unreachable
            lappend unreachable [list $file [dict get $command line] \
                                     [expr {[llength $commands] - $i}]]
            break
        }
    }
}

# Walks a script. parent is the id of the enclosing form with a body.
proc ff::WalkScript {text firstLine parent} {
    # tp::parse keeps its state in namespace variables, so finish parsing
    # this level before descending.
    set commands [tp::parse $text $firstLine]
    foreach command $commands {
        ff::WalkCommand $command $parent
    }
}

# A body word: walks it if it is a braced literal. Returns 1 if walked.
proc ff::WalkBody {word parent} {
    if {$word eq ""} { return 0 }
    if {[dict get $word form] eq "braced" && [tp::isStatic $word] &&
        [llength [dict get $word parts]] == 1} {
        ff::WalkScript [tp::value $word] [dict get $word line] $parent
        return 1
    }
    # Anything else is computed at run time. Its variable reads and command
    # substitutions were already walked by ff::WalkCommand.
    return 0
}

# An expression word: walks the command substitutions inside it.
proc ff::WalkExpr {word parent} {
    if {$word ne "" && [tp::isStatic $word]} {
        ff::WalkSubstParts [tp::parseSubst [tp::value $word] \
                                [dict get $word line]] $parent
    }
}

proc ff::WalkSubstParts {parts parent} {
    foreach part $parts {
        lassign $part type text line
        switch $type {
            cmd { ff::WalkScript $text $line $parent }
            exprsugar {
                ff::WalkSubstParts [tp::parseSubst \
                                        [string range $text 1 end-1]] $parent
            }
            var { ff::ScopeNote $parent reads [list $text] }
            dictsugar {
                set paren [string first "(" $text]
                ff::ScopeNote $parent reads \
                    [list [string range $text 0 $paren-1]]
                ff::WalkSubstParts [tp::parseSubst \
                    [string range $text $paren+1 end-1]] $parent
            }
        }
    }
}

# Walks the [cmd] and $(expr) parts of a word.
proc ff::WalkSubstitutions {word parent} {
    foreach part [dict get $word parts] {
        lassign $part type text line
        if {$type eq "cmd"} {
            ff::WalkScript $text $line $parent
        } elseif {$type eq "exprsugar"} {
            ff::WalkSubstParts [tp::parseSubst \
                                    [string range $text 1 end-1]] $parent
        }
    }
}

# Records the variables a word reads.
proc ff::NoteReads {word parent} {
    foreach part [dict get $word parts] {
        lassign $part type text
        if {$type eq "var"} {
            ff::ScopeNote $parent reads [list $text]
        } elseif {$type eq "dictsugar"} {
            set paren [string first "(" $text]
            ff::ScopeNote $parent reads [list [string range $text 0 $paren-1]]
            ff::WalkSubstParts [tp::parseSubst \
                [string range $text $paren+1 end-1]] $parent
        }
    }
}

# Does this text, parsed as a script, contain a Folk form at command
# position (at any depth of plain braces)? Used for commands we know
# nothing about.
proc ff::LooksLikeFolk {text depth} {
    variable formNames
    if {$depth > 3 || [string first "\n" $text] < 0} { return 0 }
    set found 0
    foreach name $formNames {
        if {[string first $name $text] >= 0} { set found 1; break }
    }
    if {!$found} { return 0 }
    set commands [tp::parse $text]
    if {[tp::missing] ne ""} { return 0 }
    foreach command $commands {
        set first [lindex [dict get $command words] 0]
        if {[ff::Value $first] in $formNames &&
            [llength [dict get $command words]] > 1} { return 1 }
    }
    return 0
}

proc ff::WalkCommand {command parent} {
    set words [dict get $command words]
    set line [dict get $command line]
    set name [ff::Value [lindex $words 0]]
    set av [lrange $words 1 end]

    # `local proc ...`
    if {$name eq "local" && [llength $av]} {
        set name [ff::Value [lindex $av 0]]
        set av [lrange $av 1 end]
    }

    # Every word's variable reads and command substitutions count,
    # whatever the command is. Bodies and expressions are handled by the
    # command-specific code below.
    foreach word $words {
        ff::NoteReads $word $parent
        ff::WalkSubstitutions $word $parent
    }
    if {[string index $name 0] ne "\x01"} {
        variable callSites; variable file; variable guessing
        ff::ScopeNote $parent calls [list $name]
        if {!$guessing} { lappend callSites [list $name $file $line] }
    }
    if {$name in {Claim Wish Hold!}} {
        # These read `this` from the calling scope.
        ff::ScopeNote $parent reads {this}
    }

    variable forms
    set firstNew [llength $forms]
    switch -- $name {
        When { ff::When $av $line $parent }
        Claim - Wish - Say { ff::Say $name $av $line $parent }
        Hold! { ff::Hold $av $line $parent }
        Assert! { ff::Assert $av $line $parent }
        Retract! {
            set id [ff::Add retract $name $line $parent]
            set clause [lmap word $av { ff::Term $word }]
            ff::Set $id clauses [list $clause]
            ff::CheckPattern $id $clause
        }
        Subscribe: {
            set id [ff::Add subscribe $name $line $parent]
            set clause [lmap word [lrange $av 0 end-1] { ff::Term $word }]
            ff::Set $id clauses [list $clause]
            ff::CheckPattern $id $clause
            ff::ScopeNote $id binds [ff::BoundNames [list $clause]]
            if {[llength $av] == 0} {
                ff::Diag $id grammar "Subscribe: needs a pattern and a body"
            } else {
                ff::Set $id body [ff::WalkBody [lindex $av end] $id]
            }
        }
        Notify: {
            set id [ff::Add notify $name $line $parent]
            ff::Set $id clauses [list [lmap word $av { ff::Term $word }]]
            if {[llength $av] == 0} {
                ff::Diag $id grammar "Notify: needs a clause"
            }
        }
        On {
            set id [ff::Add unmatch $name $line $parent]
            if {[ff::Value [lindex $av 0]] ne "unmatch" ||
                [llength $av] != 2} {
                ff::Diag $id grammar "expected: On unmatch body"
            } else {
                ff::Set $id body [ff::WalkBody [lindex $av 1] $id]
            }
        }
        Query! - QuerySimple! - QueryOne! - Require! - Expect! - ForEach! {
            ff::Query $name $av $line $parent
        }
        fn { ff::Fn $av $line $parent }
        default { ff::WalkTcl $name $av $line $parent; return }
    }
    # The form this command created is the first one added by the dispatch.
    if {$name ne "fn" && [llength $forms] > $firstNew} {
        ff::EmbeddedPatterns $firstNew $av
    }
}

# When ?options? pattern ?& pattern ...? body
proc ff::When {av line parent} {
    variable whenFlags; variable whenValued
    set id [ff::Add when When $line $parent]
    if {[llength $av] == 0} {
        ff::Diag $id grammar "When needs a body"
        return
    }
    set bodyWord [lindex $av end]
    set clauses {}
    set allOpts {}
    foreach segment [ff::SplitJoin [lrange $av 0 end-1]] {
        lassign [ff::SplitOptions $segment $whenFlags $whenValued] \
            opts terms positions
        set clause [lmap word $terms { ff::Term $word }]
        lappend clauses $clause
        set allOpts [dict merge $allOpts $opts]
        ff::CheckPattern $id $clause
        ff::CheckDuration $id $opts
        ff::CheckLateOptions $id $positions
    }
    if {[llength $clauses] > 1} {
        foreach clause $clauses {
            if {[llength $clause] == 0} {
                ff::Diag $id grammar "empty clause next to &"
            }
        }
    }
    ff::Set $id clauses $clauses
    ff::Set $id opts $allOpts
    ff::ScopeNote $id binds [ff::BoundNames $clauses]

    # `When the collected results for PATTERN are /x/` consumes PATTERN.
    set first [lindex $clauses 0]
    set collected [ff::CollectedPattern $first \
                       [lindex [ff::SplitJoin [lrange $av 0 end-1]] 0]]
    if {$collected ne ""} { ff::Set $id collected $collected }

    if {[dict get $bodyWord form] ne "braced" && [tp::isStatic $bodyWord]} {
        ff::Diag $id grammar "When body is a bare word"
    }
    ff::Set $id body [ff::WalkBody $bodyWord $id]
}

# If clause is `the collected results for P [with settle S] are /x/`,
# returns P as a clause (list of terms), else "". words are the words the
# clause was built from, options included.
proc ff::CollectedPattern {clause words} {
    variable whenFlags; variable whenValued
    if {[lrange $clause 0 3] ne
        {{lit the} {lit collected} {lit results} {lit for}}} { return "" }
    lassign [ff::SplitOptions $words $whenFlags $whenValued] _ terms
    set word [lindex $terms 4]
    if {$word eq ""} { return "" }
    if {[tp::isStatic $word]} {
        # A literal Tcl list.
        if {[catch {lmap item [tp::value $word] { ff::classify $item }} terms]} {
            return [list [list splat [tp::render $word]]]
        }
        return $terms
    }
    # A pattern built with [list ...] is found by ff::EmbeddedPatterns.
    return ""
}

# Patterns are also passed around as data, most often to the collector:
#   Wish to collect results for [list /p/ has quad /q/] with settle 5ms
#   Query! the collected results for [list ...] are /results/
# Any word that is exactly `[list ...]` and has a /variable/ among its terms
# is recorded on the form as an embedded pattern.
proc ff::EmbeddedPatterns {id words} {
    set found {}
    foreach word $words {
        if {$word eq "" || [dict get $word expand]} { continue }
        set parts [dict get $word parts]
        if {[llength $parts] != 1 || [lindex $parts 0 0] ne "cmd"} { continue }
        set commands [tp::parse [lindex $parts 0 1]]
        if {[llength $commands] != 1} { continue }
        set inner [dict get [lindex $commands 0] words]
        if {[ff::Value [lindex $inner 0]] ne "list"} { continue }
        set terms [lmap w [lrange $inner 1 end] { ff::Term $w }]
        foreach term $terms {
            if {[lindex $term 0] in {var rest wild neg}} {
                lappend found $terms
                break
            }
        }
    }
    if {[llength $found]} { ff::Set $id embedded $found }
}

# Claim / Wish / Say ?options? clause
proc ff::Say {cmd av line parent} {
    variable sayFlags; variable sayValued
    set kind [string tolower $cmd]
    set id [ff::Add $kind $cmd $line $parent]
    lassign [ff::SplitOptions $av $sayFlags $sayValued] opts terms positions
    set clause [lmap word $terms { ff::Term $word }]
    ff::Set $id clauses [list $clause]
    ff::Set $id opts $opts
    ff::CheckDuration $id $opts
    ff::CheckLateOptions $id $positions
    if {[llength $clause] == 0} {
        ff::Diag $id grammar "$cmd needs a clause"
    }
    foreach term $clause {
        lassign $term type name
        if {$type in {var rest wild neg}} {
            ff::Diag $id varinclause \
                "emitted term /$name/ is a variable: stored statements\
                 match patterns in both directions"
        }
    }
    # `... with ... handler BODY`: the word after `handler` is a body that
    # Say wraps with the captured environment.
    set sawWith 0
    for {set i 0} {$i < [llength $terms]} {incr i} {
        set value [ff::Value [lindex $terms $i]]
        if {$value eq "with"} {
            set sawWith 1
        } elseif {$sawWith && $value eq "handler" &&
                  $i + 1 < [llength $terms]} {
            set handler [ff::Add handler $cmd $line $parent]
            ff::Set $handler body [ff::WalkBody [lindex $terms $i+1] $handler]
        }
    }
}

# Hold! ?options? ( body | Claim clause | Wish clause | clause | "" )
proc ff::Hold {av line parent} {
    variable holdFlags; variable holdValued
    set id [ff::Add hold Hold! $line $parent]
    lassign [ff::SplitOptions $av $holdFlags $holdValued "--"] \
        opts terms positions
    ff::Set $id opts $opts
    ff::CheckDuration $id $opts
    ff::CheckLateOptions $id $positions

    if {[llength $terms] == 0} {
        # No clause at all clears the key, like an empty one.
        ff::Set $id emits clear
    } elseif {[llength $terms] == 1} {
        set word [lindex $terms 0]
        if {[ff::Value $word] eq ""} {
            ff::Set $id emits clear
        } else {
            ff::Set $id emits rule
            ff::Set $id body [ff::WalkBody $word $id]
        }
    } else {
        set head [ff::Value [lindex $terms 0]]
        if {$head eq "Claim"} {
            ff::Set $id emits claim
            set terms [lrange $terms 1 end]
        } elseif {$head eq "Wish"} {
            ff::Set $id emits wish
            set terms [lrange $terms 1 end]
        } else {
            ff::Set $id emits say
        }
        ff::Set $id clauses [list [lmap word $terms { ff::Term $word }]]
    }
}

# Assert! clause. `Assert! when PATTERN BODY with environment ENV` is a
# rule and its body is walked.
proc ff::Assert {av line parent} {
    set clause [lmap word $av { ff::Term $word }]
    if {[lindex $clause 0] eq {lit when} && [llength $clause] >= 5 &&
        [lindex $clause end-2] eq {lit with} &&
        [lindex $clause end-1] eq {lit environment}} {
        set id [ff::Add when Assert! $line $parent]
        set pattern [lrange $clause 1 end-4]
        ff::Set $id clauses [list $pattern]
        ff::CheckPattern $id $pattern
        ff::ScopeNote $id binds [ff::BoundNames [list $pattern]]
        ff::Set $id body [ff::WalkBody [lindex $av end-3] $id]
        return
    }
    set id [ff::Add assert Assert! $line $parent]
    ff::Set $id clauses [list $clause]
    if {[llength $clause] == 0} {
        ff::Diag $id grammar "Assert! needs a clause"
    }
}

# Query! ?-atomically? pattern ?& pattern ...?     and friends
proc ff::Query {cmd av line parent} {
    set id [ff::Add query $cmd $line $parent]
    set bodyWord ""
    if {$cmd eq "ForEach!"} {
        if {[llength $av] == 0} {
            ff::Diag $id grammar "ForEach! needs a pattern and a body"
            return
        }
        set bodyWord [lindex $av end]
        set av [lrange $av 0 end-1]
    }
    set flags {-atomically}
    set valued {}
    if {$cmd eq "QueryOne!"} { set valued {-default} }
    if {$cmd eq "QuerySimple!"} {
        # QuerySimple! isAtomically pattern
        set av [lrange $av 1 end]
        set flags {}
    }
    set clauses {}
    set allOpts {}
    foreach segment [ff::SplitJoin $av] {
        lassign [ff::SplitOptions $segment $flags $valued] opts terms positions
        set clause [lmap word $terms { ff::Term $word }]
        lappend clauses $clause
        set allOpts [dict merge $allOpts $opts]
        ff::CheckPattern $id $clause
        ff::CheckLateOptions $id $positions
    }
    ff::Set $id clauses $clauses
    ff::Set $id opts $allOpts
    if {[llength [lindex $clauses 0]] == 0} {
        ff::Diag $id grammar "$cmd needs a pattern"
    }
    if {$cmd in {Require! Expect!}} {
        # These set the pattern's variables in the calling scope.
        ff::ScopeNote $parent binds [ff::BoundNames $clauses]
    }
    if {$bodyWord ne ""} {
        # ForEach! runs its body in the caller's scope with the bindings.
        ff::ScopeNote $parent binds [ff::BoundNames $clauses]
        ff::Set $id body [ff::WalkBody $bodyWord $parent]
    }
}

# fn name params body | fn name
proc ff::Fn {av line parent} {
    set id [ff::Add fn fn $line $parent]
    set name [ff::Value [lindex $av 0]]
    ff::Set $id name $name
    variable definitions; variable file
    lappend definitions [list $name $file $line]
    if {[llength $av] == 3} {
        ff::ScopeNote $parent binds [list ^$name]
        set params [lindex $av 1]
        if {[tp::isStatic $params]} {
            set names [lmap param [tp::value $params] { lindex $param 0 }]
            ff::ScopeNote $id binds $names
        }
        ff::Set $id body [ff::WalkBody [lindex $av 2] $id]
    } elseif {[llength $av] == 1} {
        ff::ScopeNote $parent reads [list ^$name]
    } else {
        ff::Diag $id grammar "expected: fn name params body, or fn name"
    }
}

# Plain Tcl commands: find the script bodies and expressions inside, and
# note which variables the command assigns.
proc ff::WalkTcl {name av line parent} {
    set n [llength $av]
    switch -- $name {
        set {
            if {$n == 2} { ff::NoteBind [lindex $av 0] $parent }
            if {$n == 1} {
                ff::ScopeNote $parent reads [list [ff::Value [lindex $av 0]]]
            }
        }
        incr - append - lappend - lset {
            if {$n >= 1} {
                ff::NoteBind [lindex $av 0] $parent
                ff::ScopeNote $parent reads [list [ff::Value [lindex $av 0]]]
            }
        }
        lassign {
            foreach word [lrange $av 1 end] { ff::NoteBind $word $parent }
        }
        rename {
            if {$n == 2} {
                variable definitions; variable file
                lappend definitions [list [ff::Value [lindex $av 1]] $file $line]
            }
        }
        upvar - global - variable {
            foreach word $av { ff::NoteBind $word $parent }
        }
        dict {
            set sub [ff::Value [lindex $av 0]]
            if {$sub in {set lappend incr append unset}} {
                ff::NoteBind [lindex $av 1] $parent
                ff::ScopeNote $parent reads [list [ff::Value [lindex $av 1]]]
            } elseif {$sub in {for map}} {
                ff::NoteBindList [lindex $av 1] $parent
                if {$n == 4} { ff::WalkBody [lindex $av 3] $parent }
            } elseif {$sub eq "with"} {
                ff::ScopeNote $parent reads [list [ff::Value [lindex $av 1]]]
                if {$n >= 3} { ff::WalkBody [lindex $av end] $parent }
            } elseif {$sub in {exists get getdef size keys values}} {
                # reads only
            }
        }
        info {
            if {[ff::Value [lindex $av 0]] eq "exists" && $n == 2} {
                ff::ScopeNote $parent reads [list [ff::Value [lindex $av 1]]]
            }
        }
        regexp - scan {
            # Match variables come after the pattern; over-approximate by
            # treating every bare name-like trailing word as a binding.
            foreach word [lrange $av 2 end] {
                set value [ff::Value $word]
                if {[regexp {^[A-Za-z_][A-Za-z0-9_]*$} $value]} {
                    ff::ScopeNote $parent binds [list $value]
                }
            }
        }
        if {
            # if cond ?then? body ?elseif cond ?then? body?... ?else? ?body?
            set i 0
            while {$i < $n} {
                ff::WalkExpr [lindex $av $i] $parent
                incr i
                if {[ff::Value [lindex $av $i]] eq "then"} { incr i }
                if {$i < $n} { ff::WalkBody [lindex $av $i] $parent }
                incr i
                set keyword [ff::Value [lindex $av $i]]
                if {$keyword eq "elseif"} {
                    incr i
                } elseif {$keyword eq "else"} {
                    incr i
                    if {$i < $n} { ff::WalkBody [lindex $av $i] $parent }
                    break
                } elseif {$i < $n} {
                    ff::WalkBody [lindex $av $i] $parent
                    break
                }
            }
        }
        while {
            if {$n == 2} {
                ff::WalkExpr [lindex $av 0] $parent
                ff::WalkBody [lindex $av 1] $parent
            }
        }
        for {
            if {$n == 4} {
                ff::WalkBody [lindex $av 0] $parent
                ff::WalkExpr [lindex $av 1] $parent
                ff::WalkBody [lindex $av 2] $parent
                ff::WalkBody [lindex $av 3] $parent
            }
        }
        foreach - lmap {
            for {set i 0} {$i + 1 < $n} {incr i 2} {
                ff::NoteBindList [lindex $av $i] $parent
            }
            if {$n >= 3} { ff::WalkBody [lindex $av end] $parent }
        }
        expr - assert {
            foreach word $av { ff::WalkExpr $word $parent }
        }
        catch {
            set i 0
            while {$i < $n && [string index [ff::Value [lindex $av $i]] 0] eq "-"} {
                incr i
            }
            if {$i < $n} { ff::WalkBody [lindex $av $i] $parent }
            foreach word [lrange $av $i+1 end] { ff::NoteBind $word $parent }
        }
        try {
            # try body ?on code vars body? ?trap pat vars body? ?finally body?
            set i 0
            while {$i < $n && [string index [ff::Value [lindex $av $i]] 0] eq "-"} {
                incr i
            }
            if {$i < $n} { ff::WalkBody [lindex $av $i] $parent }
            incr i
            while {$i < $n} {
                set keyword [ff::Value [lindex $av $i]]
                if {$keyword in {on trap} && $i + 3 < $n} {
                    ff::NoteBindList [lindex $av $i+2] $parent
                    ff::WalkBody [lindex $av $i+3] $parent
                    incr i 4
                } elseif {$keyword eq "finally" && $i + 1 < $n} {
                    ff::WalkBody [lindex $av $i+1] $parent
                    incr i 2
                } else {
                    break
                }
            }
        }
        switch {
            # Bodies are either the tail words or one braced list.
            set i 0
            while {$i < $n && [string index [ff::Value [lindex $av $i]] 0] eq "-"} {
                set option [ff::Value [lindex $av $i]]
                incr i
                if {$option eq "--"} { break }
                if {$option eq "-command"} { incr i }
            }
            incr i
            set rest [lrange $av $i end]
            if {[llength $rest] == 1 && [tp::isStatic [lindex $rest 0]]} {
                # switch $x { pattern body ... }: re-parse the list as words.
                set word [lindex $rest 0]
                set inner [tp::parse [tp::value $word] [dict get $word line]]
                set items {}
                foreach command $inner {
                    foreach w [dict get $command words] { lappend items $w }
                }
                foreach {pattern body} $items {
                    if {$body ne ""} { ff::WalkBody $body $parent }
                }
            } else {
                foreach {pattern body} $rest {
                    if {$body ne ""} { ff::WalkBody $body $parent }
                }
            }
        }
        proc {
            # A proc body is its own Tcl scope: nothing is captured.
            set id [ff::Add proc proc $line $parent]
            if {$n >= 3} {
                variable definitions; variable file
                lappend definitions [list [ff::Value [lindex $av 0]] $file $line]
                ff::Set $id name [ff::Value [lindex $av 0]]
                set params [lindex $av 1]
                if {[tp::isStatic $params]} {
                    ff::ScopeNote $id binds \
                        [lmap param [tp::value $params] { lindex $param 0 }]
                }
                ff::Set $id body [ff::WalkBody [lindex $av end] $id]
            }
        }
        namespace {
            if {[ff::Value [lindex $av 0]] eq "eval" && $n == 3} {
                ff::WalkBody [lindex $av 2] $parent
            }
        }
        uplevel - eval - time - baretime {
            if {$n >= 1} { ff::WalkBody [lindex $av end] $parent }
        }
        library {
            if {[ff::Value [lindex $av 0]] eq "create" && $n >= 2} {
                set id [ff::Add proc library $line $parent]
                ff::Set $id body [ff::WalkBody [lindex $av end] $id]
            }
        }
        default {
            # Unknown command. Walk a braced argument only if it clearly
            # contains Folk forms.
            foreach word $av {
                if {[dict get $word form] eq "braced" && [tp::isStatic $word] &&
                    [llength [dict get $word parts]] == 1} {
                    set text [tp::value $word]
                    if {[ff::LooksLikeFolk $text 0]} {
                        variable guessing
                        set id [ff::Add proc $name $line $parent]
                        ff::Set $id heuristic 1
                        ff::Set $id body 1
                        incr guessing
                        ff::WalkScript $text [dict get $word line] $id
                        incr guessing -1
                    }
                }
            }
        }
    }
}

proc ff::NoteBind {word parent} {
    set value [ff::Value $word]
    if {[regexp {^[^\x01 ]+$} $value]} {
        ff::ScopeNote $parent binds [list $value]
    }
}
proc ff::NoteBindList {word parent} {
    if {[tp::isStatic $word]} {
        foreach name [tp::value $word] {
            ff::ScopeNote $parent binds [list $name]
        }
    }
}
