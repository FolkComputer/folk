catch {
    package require starkit
    starkit::startup
}

proc d {arg} {
    # puts $arg
}
proc lremove {l val} {
    set posn [lsearch -exact $l $val]
    lreplace $l $posn $posn
}

source "lib/c.tcl"
source "lib/trie.tcl"
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    namespace ensemble create
}
proc triefy {clause} {
    lmap word $clause {expr { [regexp {^/([^/ ]+)/$} $word] ? "?" : $word }}
}

namespace eval statement { ;# statement record type
    namespace export create
    proc create {clause {parentMatchIds {}} {childMatchIds {}}} {
        # clause = [list the fox is out]
        # parentMatchIds = [dict create 503 true 208 true]
        # childMatchIds = [dict create 101 true 433 true]
        return [dict create \
                    clause $clause \
                    parentMatchIds $parentMatchIds \
                    childMatchIds $childMatchIds]
    }

    namespace export clause parentMatchIds childMatchIds
    proc clause {stmt} { dict get $stmt clause }
    proc parentMatchIds {stmt} { dict get $stmt parentMatchIds }
    proc childMatchIds {stmt} { dict get $stmt childMatchIds }

    namespace export short
    proc short {stmt} {
        set lines [split [clause $stmt] "\n"]
        set line [lindex $lines 0]
        if {[string length $line] > 80} {set line "[string range $line 0 80]..."}
        dict with stmt { format "{%s} %s {%s}" $parentMatchIds $line $childMatchIds }
    }

    namespace ensemble create
}

namespace eval Statements { ;# singleton Statement store
    variable statements [dict create] ;# Dict<StatementId, Statement>
    variable nextStatementId 1
    variable statementClauseToId [trie create] ;# Trie<StatementClause, StatementId>

    # Dict<MatchId, [parentStatementIds: List<StatementId>, childStatementIds: List<StatementId>]>
    variable matches [dict create]
    variable nextMatchId 1

    proc reset {} {
        variable statements
        variable nextStatementId
        variable statementClauseToId
        set statements [dict create]
        set nextStatementId 1
        set statementClauseToId [trie create]
        variable matches; variable nextMatchId
        set matches [dict create]
        set nextMatchId 1
    }

    proc addMatch {parentStatementIds} {
        variable matches
        variable nextMatchId
        set matchId [incr nextMatchId]
        set match [dict create \
                       parentStatementIds $parentStatementIds \
                       childStatementIds [list] \
                       destructor {}]
        dict set matches $matchId $match
        foreach parentStatementId $parentStatementIds {
            dict with Statements::statements $parentStatementId {
                dict set childMatchIds $matchId true
            }
        }
        set matchId
    }

    proc add {clause {newParentMatchIds {{} true}}} {
        # empty set in newParentMatchIds = an assertion
 
        variable statements
        variable nextStatementId
        variable statementClauseToId

        # is this clause already present in the existing statement set?
        set ids [trie lookup $statementClauseToId [triefy $clause]]
        if {[llength $ids] == 1} {
            set id [lindex $ids 0]
        } elseif {[llength $ids] == 0} {
            set id false
        } else {
            error "WTF: Looked up {$clause}"
        }

        set isNewStatement [expr {$id eq false}]
        if {$isNewStatement} {
            set id [incr nextStatementId]
            set stmt [statement create $clause $newParentMatchIds]
            dict set statements $id $stmt
            trie add statementClauseToId [triefy $clause] $id
        } else {
            dict with statements $id {
                set parentMatchIds [dict merge $parentMatchIds $newParentMatchIds]
            }
        }

        dict for {parentMatchId _} $newParentMatchIds {
            if {$parentMatchId eq {}} { continue }
            dict with Statements::matches $parentMatchId {
                lappend childStatementIds $id
            }
        }

        list $id $isNewStatement
    }
    proc exists {id} { variable statements; return [dict exists $statements $id] }
    proc get {id} { variable statements; return [dict get $statements $id] }
    proc remove {id} {
        variable statements
        variable statementClauseToId
        set clause [statement clause [get $id]]
        dict unset statements $id
        trie remove statementClauseToId [triefy $clause]
    }
    proc size {} { variable statements; return [dict size $statements] }
    proc countMatches {} {
        variable statements
        set count 0
        dict for {_ stmt} $statements {
            set count [expr {$count + [dict size [statement parentMatchIds $stmt]]}]
        }
        return $count
    }
    
    proc unify {a b} {
        if {[llength $a] != [llength $b]} { return false }

        set match [dict create]
        for {set i 0} {$i < [llength $a]} {incr i} {
            set aWord [lindex $a $i]
            set bWord [lindex $b $i]
            if {[regexp {^/([^/ ]+)/$} $aWord -> aVarName]} {
                dict set match $aVarName $bWord
            } elseif {[regexp {^/([^/ ]+)/$} $bWord -> bVarName]} {
                dict set match $bVarName $aWord
            } elseif {$aWord != $bWord} {
                return false
            }
        }
        return $match
    }
    proc findMatches {pattern} {
        variable statementClauseToId
        variable statements
        # Returns a list of bindings like
        # {{name Bob age 27 __matcheeId 6} {name Omar age 28 __matcheeId 7}}

        set matches [list]
        foreach id [trie lookup $statementClauseToId [triefy $pattern]] {
            set match [unify $pattern [statement clause [get $id]]]
            if {$match != false} {
                dict set match __matcheeId $id
                lappend matches $match
            }
        }

        return $matches
    }

    proc print {} {
        variable statements
        puts "Statements"
        puts "=========="
        dict for {id stmt} $statements { puts "$id: [statement short $stmt]" }
    }
    proc dot {} {
        variable statements
        set dot [list]
        dict for {id stmt} $statements {
            lappend dot "subgraph cluster_$id {"
            lappend dot "color=lightgray;"

            set label [statement clause $stmt]
            set label [join [lmap line [split $label "\n"] {
                expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
            }] "\n"]
            set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
            lappend dot "$id \[label=\"$id: $label\"\];"

            dict for {matchId parents} [statement parentMatchIds $stmt] {
                lappend dot "\"$id $matchId\" \[label=\"$id#$matchId: $parents\"\];"
                lappend dot "\"$id $matchId\" -> $id;"
            }

            lappend dot "}"
            dict for {child _} [statement childMatchIds $stmt] {
                lappend dot "$id -> \"$child\";"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
    }
}

set ::log [list]

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {lappend ::log [list Assert $args]}
proc Retract {args} {lappend ::log [list Retract $args]}

# invoke from within a When context, add dependent statements
proc Say {args} {
    upvar __matchId matchId
    set ::log [linsert $::log 0 [list Say $matchId $args]]
}
proc Claim {args} { uplevel [list Say someone claims {*}$args] }
proc Wish {args} { uplevel [list Say someone wishes {*}$args] }
proc When {args} {
    set env [uplevel {
        set ___env $__env ;# inherit existing environment

        # get local variables and serialize them
        # (to fake lexical scope)
        foreach localName [info locals] {
            if {![string match "__*" $localName]} {
                dict set ___env $localName [set $localName]
            }
        }
        dict for {procName procArgs} $WhenContext::procs {
            dict set ___env ^$procName $procArgs
        }
        set ___env
    }]
    uplevel [list Say when {*}$args with environment $env]
}
proc On {event body} {
    if {$event eq "unmatch"} {
        upvar __matchId matchId
        dict set Statements::matches $matchId destructor $body
    } elseif {$event eq "convergence"} {
        # FIXME: this should get retracted if gthe match is retracted (?)

        # FIXME: there should be `Before convergence` also --
        # then avoid using `On convergence` to generate statements
        lappend ::log [list Do $body]
    }
}
namespace eval ::WhenContext {
    # used to collect procs created in When
    ::proc proc {name args} {
        variable procs; dict set procs $name $args
        ::proc $name {*}$args
    }
}

proc StepImpl {} {
    # should this do reduction of assert/retract ?

    proc runWhen {__env __body} {
        set ::WhenContext::__env $__env
        set ::WhenContext::__body $__body
        namespace eval ::WhenContext {
            variable procs [dict create]
            dict for {name value} $__env {
                if {[string index $name 0] eq "^"} {
                    ::proc [string range $name 1 end] {*}$value
                }
            }
            if {[catch {dict with __env $__body} err] == 1} {
                puts "$::nodename: Error: $err\n$::errorInfo"
            }
        }
        # TODO: clean up new procs (and __env and __body) in WhenContext?
    }

    proc reactToStatementAddition {id} {
        set clause [statement clause [Statements::get $id]]
        if {[lindex $clause 0] == "when"} {
            # is this a When? match it against existing statements
            # when the time is /t/ { ... } with environment /env/ -> the time is /t/
            set unwhenizedClause [lreplace [lreplace $clause end-3 end] 0 0]
            set matches [concat [Statements::findMatches $unwhenizedClause] \
                             [Statements::findMatches [list /someone/ claims {*}$unwhenizedClause]]]
            set body [lindex $clause end-3]
            set env [lindex $clause end]
            foreach match $matches {
                set matchId [Statements::addMatch [list $id [dict get $match __matcheeId]]]
                set __env [dict merge \
                               $env \
                               $match \
                               [dict create __matchId $matchId]]
                runWhen $__env $body
            }
        }

        # match this statement against existing whens
        # the time is 3 -> when the time is 3 /__body/ with environment /__env/
        proc whenize {clause} { return [list when {*}$clause /__body/ with environment /__env/] }
        set matches [Statements::findMatches [whenize $clause]]
        if {[Statements::unify [lrange $clause 0 1] [list /someone/ claims]] != false} {
            # Omar claims the time is 3 -> when the time is 3 /__body/ with environment /__env/
            lappend matches {*}[Statements::findMatches [whenize [lrange $clause 2 end]]]
        }
        foreach match $matches {
            set matchId [Statements::addMatch [list $id [dict get $match __matcheeId]]]
            set __env [dict merge \
                           [dict get $match __env] \
                           $match \
                           [dict create __matchId $matchId]]
            runWhen $__env [dict get $match __body]
        }
    }
    proc reactToStatementRemoval {id} {
        # unset all things downstream of statement
        set childMatchIds [statement childMatchIds [Statements::get $id]]
        dict for {matchId _} $childMatchIds {
            if {![dict exists $Statements::matches $matchId]} { continue } ;# if was removed earlier

            dict with Statements::matches $matchId {
                # this match will be dead, so remove the match from the
                # other parents of the match
                foreach parentStatementId $parentStatementIds {
                    if {![Statements::exists $parentStatementId]} { continue }
                    dict with Statements::statements $parentStatementId {
                        dict unset childMatchIds $matchId
                    }
                }

                foreach childStatementId $childStatementIds {
                    if {![Statements::exists $childStatementId]} { continue }
                    dict with Statements::statements $childStatementId {
                        dict unset parentMatchIds $matchId

                        # is this child out of parent matches? => it's dead
                        if {[dict size $parentMatchIds] == 0} {
                            reactToStatementRemoval $childStatementId
                            Statements::remove $childStatementId
                            set childStatementIds [lremove $childStatementIds $childStatementId]
                        }
                    }
                }

                eval $destructor
            }
            dict unset Statements::matches $matchId
        }
    }

    # d ""
    # d "Step:"
    # d "-----"

    # puts "Now processing log: $::log"
    set ::logsize [llength $::log]
    while {[llength $::log]} {
        # TODO: make this log-shift more efficient?
        set entry [lindex $::log 0]
        set ::log [lreplace $::log 0 0]

        set op [lindex $entry 0]
        # d "$op: [string map {\n { }} [string range $entry 0 100]]"
        if {$op == "Assert"} {
            set clause [lindex $entry 1]
            # insert empty environment if not present
            if {[lindex $clause 0] == "when" && [lrange $clause end-2 end-1] != "with environment"} {
                set clause [list {*}$clause with environment {}]
            }
            lassign [Statements::add $clause] id isNewStatement ;# statement without parents
            if {$isNewStatement} { reactToStatementAddition $id }

        } elseif {$op == "Retract"} {
            set clause [lindex $entry 1]
            set ids [lmap match [Statements::findMatches $clause] {
                dict get $match __matcheeId
            }]
            foreach id $ids {
                reactToStatementRemoval $id
                Statements::remove $id
            }

        } elseif {$op == "Say"} {
            set parentMatchId [lindex $entry 1]
            set clause [lindex $entry 2]
            lassign [Statements::add $clause [dict create $parentMatchId true]] id isNewStatement
            if {$isNewStatement} { reactToStatementAddition $id }

        } elseif {$op == "Do"} {
            eval [lindex $entry 1]
        }
    }

    if {[namespace exists Display]} {
        Display::commit ;# TODO: this is weird, not right level
    }
}

lappend auto_path "./vendor"
package require websocket

set ::acceptNum 0
proc handleConnect {chan addr port} {
    fileevent $chan readable [list handleRead $chan $addr $port]
}
proc handlePage {path} {
    if {$path eq "/"} {
        set l [list]
        dict for {id stmt} $Statements::statements {
            lappend l [subst {
                <li>
                <details>
                <summary>$id: [statement short $stmt]</summary>
                <pre>[statement clause $stmt]</pre>
                </details>
                </li>
            }]
        }
        return "<html><ul>[join $l "\n"]</ul></html>"
    }

    subst {
        <html>
        <b>$path</b>
        </html>
    }
}
proc handleRead {chan addr port} {
    chan configure $chan -translation crlf
    gets $chan line; set firstline $line
    puts "Http: $chan $addr $port: $line"
    set headers [list]
    while {[gets $chan line] >= 0 && $line ne ""} {
        if {[regexp -expanded {^( [^\s:]+ ) \s* : \s* (.+)} $line -> k v]} {
            lappend headers $k $v
        } else { break }
    }
    if {[regexp {GET ([^ ]*) HTTP/1.1} $firstline -> path] && $path ne "/ws"} {
        puts $chan "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/html\n"
        puts $chan [handlePage $path]
        close $chan
    } elseif {[::websocket::test $::serverSock $chan "/ws" $headers]} {
        puts "WS: $chan $addr $port"
        ::websocket::upgrade $chan
        # from now the handleWS will be called (not anymore handleRead).
    } else { puts "Closing: $chan $addr $port $headers"; close $chan }
}
proc handleWS {chan type msg} {
    if {$type eq "text"} {
        if {[catch {::websocket::send $chan text [eval $msg]} err] == 1} {
            if [catch {
                puts "$::nodename: Error on receipt: $err"
                ::websocket::send $chan text $err
            } err2] { puts "$::nodename: $err2" }
        }
    }
}
set ::nodename [info hostname]
if {[catch {set ::serverSock [socket -server handleConnect 4273]}] == 1} {
    set ::nodename "[info hostname]-1"
    puts "$::nodename: Note: There's already a Folk node running on this machine."
    set ::serverSock [socket -server handleConnect 4274]
}
::websocket::server $::serverSock
::websocket::live $::serverSock /ws handleWS

set ::stepCount 0
set ::stepTime "none"
proc Step {} {
    # puts "$::nodename: Step"

    # TODO: should these be reordered?
    incr ::stepCount
    Assert $::nodename has step count $::stepCount
    Retract $::nodename has step count [expr {$::stepCount - 1}]
    set ::stepTime [time {StepImpl}]
}

source "lib/math.tcl"

# this defines $this in the contained scopes
Assert when /this/ has program code /__code/ {
    if {[catch $__code err] == 1} {
        puts "$::nodename: Error in $this: $err\n$::errorInfo"
    }
}

if {$tcl_platform(os) eq "Darwin" || [info exists ::env(DISPLAY)]} {
    if {$tcl_version eq 8.5} {
        error "Don't use Tcl 8.5 / macOS system Tcl. Quitting."
    }
}

if {[info exists ::env(FOLK_ENTRY)]} {
    set ::entry $::env(FOLK_ENTRY)

} elseif {$tcl_platform(os) eq "Darwin" || [info exists ::env(DISPLAY)]} {
    #     if {[catch {source [file join $::starkit::topdir laptop.tcl]}]} 
    set ::entry "laptop.tcl"

} else {
    set ::entry "pi/pi.tcl"
}

source $::entry
