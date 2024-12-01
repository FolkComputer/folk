proc serializeEnvironment {} {
    set argNames [list]
    set argValues [list]
    # Get all variables and serialize them, to fake lexical scope.
    foreach name [uplevel {info locals}] {
        if {![string match "__*" $name]} {
            lappend argNames $name
            lappend argValues [uplevel [list set $name]]
        }
    }
    list $argNames $argValues
}
proc assert condition {
    if {![uplevel [list expr $condition]]} {
        return -code error "assertion failed: $condition"
    }
}
namespace eval ::library {
    # statics is a list of names to capture from the surrounding
    # context.
    proc create {args} {
        if {[llength $args] == 1} {
            set name library
            set body [lindex $args 0]
            set statics {}
        } elseif {[llength $args] == 2} {
            lassign $args name body
            set statics {}
        } elseif {[llength $args] == 3} {
            lassign $args name statics body
        } else {
            error "library create: Invalid arguments"
        }
        set tclfile [file tempfile /tmp/${name}_XXXXXX].tcl

        set statics [lmap static $statics {list $static [uplevel set $static]}]
        set tclcode [list apply {{tclfile statics body} {
            foreach static $statics {
                lassign $static name value
                namespace eval ::<library:$tclfile> [list variable $name $value]
            }
            namespace eval ::<library:$tclfile> $body
            namespace eval ::<library:$tclfile> {namespace ensemble create}
        }} $tclfile $statics $body]

        set tclfd [open $tclfile w]; puts $tclfd $tclcode; close $tclfd
        return "<library:$tclfile>"
    }
    namespace ensemble create
}

proc unknown {cmdName args} {
    if {[regexp {<C:([^ ]+)>} $cmdName -> cid]} {
        # Allow C libraries to be callable from any thread, because we
        # load the library into the Tcl interpreter for a given thread
        # on demand.

        # Is it a C file? load it now.
        load /tmp/$cid.so
        proc <C:$cid> {procName args} {cid} { "<C:$cid> $procName" {*}$args }
        $cmdName {*}$args

    } elseif {[regexp {<library:([^ ]+)>} $cmdName -> tclfile]} {
        # Allow Tcl `library create` libraries to be callable from any
        # thread, because we load the library into the Tcl interpreter
        # for a given thread on demand.
        source $tclfile
        $cmdName {*}$args

    } else {
        error "Unknown command '$cmdName'"
    }
}

proc lsort_key_asc {key l} {
    return [lsort -command [list apply {{key a b} {
        expr {[dict get $a $key] < [dict get $b $key]}
    }} $key] $l]
}
proc min {args} {
    if {[llength $args] == 0} { error "min: No args" }
    set min infinity
    foreach arg $args { if {$arg < $min} { set min $arg } }
    return $min
}
proc max {args} {
    if {[llength $args] == 0} { error "max: No args" }
    set max -infinity
    foreach arg $args { if {$arg > $max} { set max $arg } }
    return $max
}
proc baretime body { string map {" microseconds per iteration" ""} [uplevel [list time $body]] }

proc Claim {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args }
proc Wish {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args }
proc When {args} {
    set body [lindex $args end]
    set args [lreplace $args end end]

    set isNonCapturing false
    set isSerially false
    set pattern [list]
    foreach term $args {
        if {$term eq "(non-capturing)"} {
            set isNonCapturing true
        } elseif {$term eq "(serially)"} {
            set isSerially true
        } else {
            lappend pattern $term
        }
    }

    if {$isNonCapturing} {
        set argNames [list]; set argValues [list]
    } else {
        lassign [uplevel serializeEnvironment] argNames argValues
    }

    if {$isSerially} {
        # Serial prologue: find this When itself; see if that
        # statement ref has any match children that are incomplete. If
        # so, then die.
        set prologue {
            if {[__isWhenOfCurrentMatchAlreadyRunning]} {
                return
            }
        }
        set body "$prologue\n$body"
    }

    set varNamesWillBeBound [list]
    set isNegated false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set term [lindex $pattern $i]
        if {$term eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingTerm [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingTerm -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            set body [list When {*}$remainingPattern $body]
            break

        } elseif {[set varName [__scanVariable $term]] != 0} {
            if {[__variableNameIsNonCapturing $varName]} {
            } elseif {$varName eq "nobody" || $varName eq "nothing"} {
                # Rewrite this entire clause to be negated.
                set isNegated true
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }
        } elseif {[__startsWithDollarSign $term]} {
            lset pattern $i [uplevel [list subst $term]]
        }
    }

    if {$isNegated} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        tailcall Say when the collected matches for $pattern are /__matches/ [list [list {*}$argNames __matches] $negateBody] with environment $argValues
    } else {
        lappend argNames {*}$varNamesWillBeBound
        tailcall Say when {*}$pattern [list $argNames $body] with environment $argValues
    }
}
proc On {event args} {
    if {$event eq "unmatch"} {
        set body [lindex $args 0]
        lassign [uplevel serializeEnvironment] argNames argValues
        Destructor [list apply [list $argNames $body] {*}$argValues]
    } else {
        error "On: Unknown $event (called with: $args)"
    }
}

set ::thisNode [info hostname]

lappend ::auto_path "./vendor"
source "lib/c.tcl"
source "lib/math.tcl"

if {[info exists ::env(TRACY_ENABLE)] && $::env(TRACY_ENABLE)} {
    set tracyCid "tracy_[pid]"
    set ::tracyLib "<C:$tracyCid>"
    set tracySo "/tmp/$tracyCid.so"
    proc tracyCompile {} {tracyCid} {
        # We should only compile this once, then load the same library
        # everywhere in Folk (no matter what thread).
        set tracyCpp [C++]
        $tracyCpp cflags -std=c++20 -I./vendor/tracy/public
        $tracyCpp include "TracyClient.cpp"
        $tracyCpp include "tracy/TracyC.h"
        $tracyCpp proc init {} void {
            fprintf(stderr, "Tracy on\n");
        }
        $tracyCpp proc message {char* x} void {
            
        }
        $tracyCpp proc frameMark {} void {
            TracyCFrameMark;
        }
        $tracyCpp proc frameMarkStart {char* x} void {
            TracyCFrameMarkStart(x);
        }
        $tracyCpp proc frameMarkEnd {char* x} void {
            TracyCFrameMarkEnd(x);
        }
        $tracyCpp code {
            TracyCZoneCtx __zoneCtx;
        }
        $tracyCpp proc zoneStart {char* x} void {
            TracyCZone(__zoneCtx, 1);
        }
        $tracyCpp proc zoneEnd {char* x} void {
            TracyCZoneEnd(__zoneCtx);
        }
        return [$tracyCpp compile $tracyCid]
    }
    proc tracyTryLoad {} {tracySo} {
        if {![file exists $tracySo]} {
            return false
        }
        $::tracyLib init
        rename $::tracyLib tracy
        return true
    }

    if {[__threadId] == 0} {
        set tracyTemp [tracyCompile]
        $tracyTemp init
        rename $tracyTemp ::tracy
    } else {
        namespace eval ::tracy {
            proc unknown {args} {
                if {[tracyTryLoad]} {
                    {*}$args
                }
            }
        }
    }

} else {
    namespace eval ::tracy {
        proc message {msg} {}
        proc frameMark {} {}
        proc frameMarkStart {x} {}
        proc frameMarkEnd {x} {}
        proc zoneStart {x} {}
        proc zoneEnd {x} {}
        namespace ensemble create
    }
}

signal handle SIGUSR1
