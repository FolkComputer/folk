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
    proc create {{name tclfile} body} {
        set tclfile [file tempfile /tmp/${name}_XXXXXX].tcl
        set tclfd [open $tclfile w]; puts $tclfd $body; close $tclfd
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
        namespace eval ::<library:$tclfile> [list source $tclfile]
        namespace eval ::<library:$tclfile> {namespace ensemble create}        
        $cmdName {*}$args

    } else {
        error "Unknown command '$cmdName'"
    }
}


proc Claim {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args }
proc Wish {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args }
proc When {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]
    if {[lindex $pattern 0] eq "(non-capturing)"} {
        set argNames [list]; set argValues [list]
        set pattern [lreplace $pattern 0 0]
    } else {
        lassign [uplevel serializeEnvironment] argNames argValues
    }

    set varNamesWillBeBound [list]
    set negate false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set word [lindex $pattern $i]
        if {$word eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingWord [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingWord -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            set body [list When {*}$remainingPattern $body]
            break

        } elseif {[set varName [__scanVariable $word]] != 0} {
            if {[__variableNameIsNonCapturing $varName]} {
            } elseif {$varName eq "nobody" || $varName eq "nothing"} {
                # Rewrite this entire clause to be negated.
                set negate true
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }
        } elseif {[__startsWithDollarSign $word]} {
            lset pattern $i [uplevel [list subst $word]]
        }
    }

    if {$negate} {
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

set ::perfEventLibs [dict create]
proc perfEvent {name} {
    if {![dict exists $::perfEventLibs $name]} {
        set perfEventCc [C]
        $perfEventCc proc $name {} void {}
        set perfEventLib [$perfEventCc compile]
        puts stderr "perfEvent: $name: sudo perf probe -x [file rootname [$perfEventCc get cfile]].so $name"
        dict set ::perfEventLibs $name $perfEventLib
    }
    [dict get $::perfEventLibs $name] $name
}
set perf [C]
$perf compile

signal handle SIGUSR1
