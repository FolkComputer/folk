# This file gets re-evaluated on every new Tcl interpreter that spins
# up, so multiple times, possibly in parallel, possibly even late in
# the lifetime of the Folk system.
#
# It's sort of the only place you can create genuine globals that you
# can guarantee will be available on any Folk process/block.

lappend ::auto_path "./vendor"
source "lib/c.tcl"
source "lib/math.tcl"

proc unknown {cmdName args} {
    if {[regexp {<C:([^ ]+)>} $cmdName -> cid]} {
        # Allow C libraries to be callable from any thread, because we
        # load the library into the Tcl interpreter for a given thread
        # on demand.

        # Is it a C file? load it now.
        if {[llength [info commands $cmdName]] == 0} {
            # HACK: somehow this keeps getting called repeatedly which
            # causes a leak??
            load /tmp/$cid.so
        }
        proc <C:$cid> {procName args} {cid} { tailcall "<C:$cid> $procName" {*}$args }
        if {[llength $args] == 0} {
            return
        }
        tailcall $cmdName {*}$args

    } elseif {[regexp {<library:([^ ]+)>} $cmdName -> tclfile]} {
        # Allow Tcl `library create` libraries to be callable from any
        # thread, because we load the library into the Tcl interpreter
        # for a given thread on demand.
        source $tclfile
        tailcall $cmdName {*}$args

    } else {
        set fnVarName ^$cmdName
        upvar $fnVarName fn
        if {[info exists fn]} {
            if {[llength $fn] == 1} {
                # fn[0] is a sealed obj that includes its own
                # environment (probably passed through a statement)
                # and can just be applied to args.
                set fnObj [lindex $fn 0]
                proc $cmdName args {fnObj} { tailcall {*}$fnObj {*}$args }
                tailcall $cmdName {*}$args
            }

            lassign $fn argNames body sourceInfo
            if {[info source $body] ne $sourceInfo} {
                set body [info source $body {*}$sourceInfo]
            }

            upvar __envStack envStack
            # Walk the env stack backwards (innermost env first) until
            # we find the fn.
            for {set i $([llength $envStack] - 1)} {$i >= 0} {incr i -1} {
                set env [lindex $envStack $i]
                if {[dict exists $env $fnVarName]} {
                    break
                }
            }
            if {$i < 0} {
                error "unknown: Did not find fn $cmdName in env stack"
            }

            # We found the function somewhere in the env stack.

            # Merge all envs up to and including envStack[i] to create
            # the lexical environment for fn.
            set env [dict merge {*}[lrange $envStack 0 $i]]
            dict set env __envStack $envStack
            dict set env __env $env
            dict with env {
                proc $cmdName $argNames [dict keys $env] $body
            }

            tailcall $cmdName {*}$args
        }
    }

    tailcall error "Unknown command '$cmdName'"
}

proc captureEnvStack {} {
    # Capture and return the lexical environment at the caller.

    upvar __env oldEnv
    if {![info exists oldEnv]} { set oldEnv {} }

    # Get all changed variables and serialize them, to fake lexical
    # scope.
    set env [dict create]
    set upNames [uplevel {list {*}[info statics] {*}[info locals]}]
    foreach name $upNames {
        if {[string match "__*" $name]} { continue }

        upvar $name value
        if {![dict exists $oldEnv $name] ||
            $value ne [dict get $oldEnv $name]} {

            dict set env $name $value
        }
    }

    return [list {*}[uplevel set __envStack] $env]
}

set ::localStdoutsAndStderrs [dict create]

proc applyBlock {body envStack} {
    set env [dict merge {*}$envStack]
    foreach name [dict keys $env] {
        if {[string index $name 0] eq "^"} {
            # Delete any old version of the fn that may exist in
            # command-space. We want to reload this one when it
            # gets called.
            try {
                rename [string index $name 1 end] {}
            } on error e {}
        }
    }

    dict set env __envStack $envStack
    dict set env __env $env

    set this [dict getdef $env this <unknown>]
    if {[dict exists $::localStdoutsAndStderrs $this]} {
        lassign [dict get $::localStdoutsAndStderrs $this] \
            localStdout localStderr
    } else {
        set escapedThis [regsub -all -- / $this __]
        set localStdout [open /tmp/$escapedThis.stdout a]
        $localStdout buffering line
        set localStderr [open /tmp/$escapedThis.stderr a]
        $localStderr buffering none
        dict set ::localStdoutsAndStderrs $this \
            [list $localStdout $localStderr]
    }
    # Stomp over whatever current stdout and stderr are, in favor of
    # these local fds, so all subsequent calls to puts/fprintf/printf
    # will go to the local stdout and stderr.
    dup2 $localStdout 1; dup2 $localStderr 2

    set names [dict keys $env]
    set values [dict values $env]
    tailcall apply [list $names $body] {*}$values
}

proc evaluateBlock {whenBody envStack} {
    try {
        applyBlock $whenBody $envStack
    } on error {err opts} {
        set errorInfo [dict get $opts -errorinfo]
        set this [lindex $errorInfo 1]
        puts stderr "\nError in $this: $err\n  [errorInfo $err $errorInfo]"
        if {[__isInSubscription]} {
            # Can't Say inside of a subscription, so Hold! instead
            # (TODO: might be a better way?)
            Hold! -key $this-error -on $this $this has error $err with info $opts
        } else {
            Say $this has error $err with info $opts
        }
    }
}

proc fn {args} {
    if {[llength $args] == 1} {
        set fnName [lindex $args 0]

        if {[uplevel info exists $fnName]} {
            upvar $fnName fnObj

            # They want to just be able to call an existing fn that
            # already exists in scope as a `fnName` variable.

            # Create this function (both in lexical variable scope, so
            # it can be inherited by child scopes, and in
            # callable-function namespace) and then return.

            uplevel [list set ^$fnName [list $fnObj]]
            proc $fnName args {fnObj} { tailcall {*}$fnObj {*}$args }
            return
        }

        # They just want to capture an existing fn + env as a
        # self-contained value, to share in a statement or
        # whatever. This is a pretty slow operation.

        upvar ^$fnName fn

        # TODO: Probably not safe to call outside the original context
        # where the fn was defined.

        set envStack [uplevel captureEnvStack]

        # Call like [{*}[fn hello] 1 2] should be equivalent to [hello
        # 1 2].
        return [list apply {{fn envStack args} {
            lassign $fn argNames body sourceInfo
            if {[info source $body] ne $sourceInfo} {
                set body [info source $body {*}$sourceInfo]
            }

            set env [dict merge {*}$envStack]
            dict set env __envStack $envStack
            dict set env __env $env
            
            set argNames [list {*}[dict keys $env] {*}$argNames]
            tailcall apply [list $argNames $body] \
                {*}[dict values $env] \
                {*}$args
        }} $fn $envStack]
    }
    lassign $args fnName argNames body

    # Creates a variable in the caller lexical env called ^$name. Our
    # custom unknown implementation will check ^$name on call.
    #
    # Note that we _don't_ capture an environment into
    # ^$name. Instead, we assume that the enclosing environment will
    # be captured later anyway (that's how you would get this
    # function! we don't expect people to pass it around really), so
    # the caller of this function will just rehydrate that enclosing
    # environment.
    uplevel [list set ^$fnName [list $argNames $body [info source $body]]]

    # In case they actually want to call the fn in the same context,
    # we make a proc immediately also:

    # We need to use tailcall here to preserve the filename/lineno
    # info for $body for some reason.
    # TODO: also capture info statics?
    tailcall proc $fnName $argNames [uplevel info locals] $body
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
        set tclcode [list apply {{tclfile statics body bodySourceInfo} {
            foreach static $statics {
                lassign $static name value
                namespace eval ::<library:$tclfile> [list variable $name $value]
            }
            namespace eval ::<library:$tclfile> [info source $body {*}$bodySourceInfo]
            namespace eval ::<library:$tclfile> {namespace ensemble create}
        }} $tclfile $statics $body [info source $body]]

        set tclfd [open $tclfile w]; puts $tclfd $tclcode; close $tclfd
        return "<library:$tclfile>"
    }
    namespace ensemble create
}

namespace eval ::math {
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
    proc mean {val args} {
        set sum $val
        set N [ expr { [ llength $args ] + 1 } ]
        foreach val $args {
            set sum [ expr { $sum + $val } ]
        }
        set mean [expr { double($sum) / $N }]
    }
    proc sin {x} { expr {sin($x)} }
    proc cos {x} { expr {cos($x)} }
}
namespace import ::math::*

proc lseq count {
    set ret [list]
    for {set i 0} {$i < $count} {incr i} {
        lappend ret $i
    }
    return $ret
}

proc baretime body { string map {" microseconds per iteration" ""} [uplevel [list time $body]] }

proc Hold! {args} {
    set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]

    set on $this
    set key [list]
    set version -1
    set clause [list]
    set keepMs 0
    set destructorCode {}
    set isNonCapturing false
    set saveHold false
    for {set i 0} {$i < [llength $args]} {incr i} {
        set arg [lindex $args $i]
        if {$arg eq "-on"} {
            incr i; set on [lindex $args $i]
        } elseif {$arg eq "-key"} {
            incr i; set key [lindex $args $i]
        } elseif {$arg eq "-keep"} { # e.g., -keep 3ms
            incr i; set keep [lindex $args $i]
            if {[string match {*ms} $keep]} {
                set keepMs [string range $keep 0 end-2]
            } else {
                error "Hold!: invalid keep value: $keep"
            }
        } elseif {$arg eq "-source"} { # e.g., -source {builtin-programs/cool.folk 3}
            incr i; lassign [lindex $args $i] filename lineno
        } elseif {$arg eq "-destructor"} {
            incr i; set destructorCode [lindex $args $i]
        } elseif {$arg eq "-version"} {
            incr i; set version [lindex $args $i]
        } elseif {$arg eq "-noncapturing"} {
            set isNonCapturing true
        } elseif {$arg eq "-save"} {
            set saveHold true
        } elseif {$arg eq "--"} {
            incr i; lappend clause {*}[lrange $args $i end]
            break
        } else {
            lappend clause $arg
        }
    }
    if {[llength $clause] == 1 && [lindex $clause 0] == ""} {
        set clause ""
    } elseif {[llength $clause] == 1} {
        # Hold! { ... body ... }
        set body [lindex $clause 0]

        if {$isNonCapturing} {
            set envStack {}
        } else {
            set envStack [uplevel captureEnvStack]
        }
        lassign [info source $body] filename lineno
        set clause [list when $body with environment $envStack]
    } elseif {[llength $clause] > 1} {
        if {[lindex $clause 0] eq "Claim"} {
            set clause [list $this claims {*}[lrange $clause 1 end]]
        } elseif {[lindex $clause 0] eq "Wish"} {
            set clause [list $this wishes {*}[lrange $clause 1 end]]
        }
    }

    if {![info exists filename] || ![info exists lineno]} {
        set frame [info frame -1]
        set filename [dict get $frame file]
        set lineno [dict get $frame line]
    }

    if {$saveHold} {
        Notify: save hold on $on with key $key clause $clause
    }

    set key [list $on {*}$key]

    tailcall HoldStatementGlobally! \
        $key $version $clause $keepMs $destructorCode \
        $filename $lineno
}

proc Say {args} {
    set callerInfo [info frame -1]
    set sourceFileName [dict get $callerInfo file]
    set sourceLineNumber [dict get $callerInfo line]

    set keepMs 0
    set atomicallyVersion [__currentAtomicallyVersion]
    set destructorCode {}

    set pattern [list]
    set isWith false
    for {set i 0} {$i < [llength $args]} {incr i} {
        set term [lindex $args $i]
        if {$term eq {-keep}} { # e.g., -keep 3ms
            incr i
            set keep [lindex $args $i]
            if {[string match {*ms} $keep]} {
                set keepMs [string range $keep 0 end-2]
            } else {
                error "Say: invalid keep value [string range $keep 0 end]"
            }
        } elseif {$term eq "-nonatomically"} {
            set atomicallyVersion {}
        } elseif {$term eq "-destructor"} {
            incr i
            set destructorCode [lindex $args $i]
        } else {
            lappend pattern $term
        }

        if {$term eq "with"} {
            # HACK: now we should keep an eye out for "handler"; we
            # want to attach the lexical scope to "with handler
            # {...}".
            set isWith true
        } elseif {$isWith && $term eq "handler"} {
            set handler [lindex $args $i+1]
            set envStack [uplevel captureEnvStack]
            lset args $i+1 [list applyBlock $handler $envStack]
        }
    }
    tailcall SayWithSource $sourceFileName $sourceLineNumber \
        $keepMs \
        $atomicallyVersion \
        $destructorCode \
        {*}$pattern
}
proc Claim {args} { upvar this this; tailcall Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args }
proc Wish {args} { upvar this this; tailcall Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args }
# returns the statement to Say/Assert (minus the envStack), as well as all bound variable names
proc desugarWhen {pattern body} {
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
                lset pattern $i "/any/"
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }
        } elseif {[__startsWithDollarSign $term]} {
            lset pattern $i [uplevel 2 [list subst $term]]
        }
    }

    if {$isNegated} {
        set negateBody [list if {[llength $__results] == 0} $body]
        return [list \
            [list when the collected results for $pattern are /__results/ \
                $negateBody with environment] \
            $varNamesWillBeBound]
    } else {
        return [list \
            [list when {*}$pattern $body with environment] \
            $varNamesWillBeBound]
    }
}
proc When {args} {
    set body [lindex $args end]
    set sourceInfo [info source $body]

    set args [lreplace $args end end]

    set isAfterAmpersand false
    set isNonCapturing false
    set isSerially false
    set atomicallyVersion "default"

    set pattern [list]
    for {set i 0} {$i < [llength $args]} {incr i} {
        set term [lindex $args $i]
        if {$isAfterAmpersand} {
            # Let the nested When handle arguments in the rest of the
            # patterns later.
            lappend pattern $term
        } elseif {$term eq "&"} {
            set isAfterAmpersand true
            lappend pattern $term
        } elseif {$term eq "-noncapturing"} {
            set isNonCapturing true
        } elseif {$term eq "-serially"} {
            set isSerially true
        } elseif {$term eq "-atomically"} {
            set key [list [uplevel set this] $sourceInfo $pattern]
            set atomicallyVersion [list "fresh" $key]
        } elseif {$term eq "-atomicallyInherit"} {
            set atomicallyVersion [__currentAtomicallyVersion]
        } elseif {$term eq "-atomicallyWithKey"} {
            incr i
            set key [lindex $args $i]
            set atomicallyVersion [list "fresh" $key]
        } elseif {$term eq "-nonatomically"} {
            set atomicallyVersion {}
        } else {
            lappend pattern $term
        }
    }

    if {$atomicallyVersion eq "default"} {
        set inheritAtomicallyVersion [__currentAtomicallyVersion]
        if {$inheritAtomicallyVersion eq {}} {
            # HACK: Default atomically on certain patterns:
            if {([lrange $pattern 1 end-1] eq {has camera slice} ||
                 [lrange $pattern 0 end-1] eq {the clock time is})} {

                set key [list [uplevel set this] $sourceInfo $pattern]
                set atomicallyVersion [list "fresh" $key]
            } else {
                set atomicallyVersion {}
            }
        } else {
            set atomicallyVersion $inheritAtomicallyVersion
        }
    }

    if {$isNonCapturing} {
        set envStack {}
    } else {
        set envStack [uplevel captureEnvStack]
    }

    if {$isSerially} {
        # Serial prologue: find this When itself; see if that
        # statement ref has any match children that are incomplete. If
        # so, then die.
        set prologue {
            if {[__whenOfCurrentMatchIncompleteChildMatchesCount] > 1} {
                return
            }
        }
        set body "$prologue\n$body"
    }

    if {[llength $atomicallyVersion] == 2 &&
        [lindex $atomicallyVersion 0] eq "fresh"} {
        # The AtomicallyVersion should be set _inside_ the When body,
        # uniquely for each execution.
        set key [lindex $atomicallyVersion 1]
        set prologue [list __setFreshAtomicallyVersionOnKey $key]
        set body "$prologue;$body"

        set atomicallyVersion {}
    }

    lassign [desugarWhen $pattern $body] statement boundVars
    lappend statement $envStack

    tailcall SayWithSource {*}$sourceInfo \
        0 $atomicallyVersion {} \
        {*}$statement
}
proc Subscribe: {args} {
    set pattern [lrange $args 0 end-1]
    set body [lindex $args end]

    set sourceInfo [info source $body]
    set envStack [uplevel captureEnvStack]

    tailcall SayWithSource {*}$sourceInfo \
        0 {} {} \
        subscribe {*}$pattern $body with environment $envStack
}
proc Notify: {args} {
    NotifyImpl {*}$args
}
proc On {event args} {
    if {$event eq "unmatch"} {
        set body [lindex $args 0]
        set envStack [uplevel captureEnvStack]
        Destructor [list applyBlock $body $envStack]
    } else {
        error "On: Unknown '$event' (called with: [string range $args 0 50]...)"
    }
}

# Query! is like QuerySimple! but with added support for & joins, and
# it'll automatically also query the claimized pattern (the pattern
# with `/someone/ claims` prepended).
proc Query! {args} {
    # HACK: this (parsing &s and filling resolved vars) is mostly
    # copy-and-pasted from When.

    set isAtomically false

    # TODO: refactor common logic out? is it worth it?

    set pattern [list]
    set varNamesWillBeBound [list]
    set isNegated false
    for {set i 0} {$i < [llength $args]} {incr i} {
        set term [lindex $args $i]
        if {$term eq "&"} {
            set remainingPattern [lrange $args $i+1 end]
            # pattern is already built up correctly before the &
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingTerm [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingTerm -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            break

        } elseif {$term eq "-atomically"} {
            set isAtomically true

        } elseif {[set varName [__scanVariable $term]] != 0} {
            if {[__variableNameIsNonCapturing $varName]} {
            } elseif {$varName eq "nobody" || $varName eq "nothing"} {
                set isNegated true
                lset args $i "/any/"
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }

            lappend pattern $term

        } elseif {[__startsWithDollarSign $term]} {
            lappend pattern [uplevel subst $term]
        } else {
            lappend pattern $term
        }
    }

    if {[llength $pattern] >= 2 && ([lindex $pattern 1] eq "claims" ||
                                    [lindex $pattern 1] eq "wishes")} {
        set results0 [QuerySimple! $isAtomically {*}$pattern]
    } else {
        # If the pattern doesn't already have `claims` or `wishes` in
        # second position, then automatically query for the claimized
        # version of the pattern as well.
        set results0 [concat [QuerySimple! $isAtomically {*}$pattern] \
                          [QuerySimple! $isAtomically /someone/ claims {*}$pattern]]
    }

    if {$isNegated} {
        if {[llength $results0] > 0} {
            set results0 {}
        } else {
            set results0 {{}}
        }
    }

    if {![info exists remainingPattern]} {
        return $results0
    }

    set results [list]
    foreach result0 $results0 {
        dict with result0 {
            foreach result [Query! {*}[if $isAtomically [list -atomically] else list] \
                                {*}$remainingPattern] {
                lappend results [dict merge $result0 $result]
            }
        }
    }
    return $results
}
proc QueryOne! {args} {
    set results [Query! {*}$args]

    if {[llength $results] != 1} {
        error "QueryOne! of ($args) had [llength $results] results. Should be one result!"
    }

    return [lindex $results 0]
}
proc ForEach! {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]

    set results [Query! {*}$pattern]
    upvar __result result
    foreach result $results {
        if {[dict exists $result __ref]} {
            set ref [dict get $result __ref]
            try {
                StatementAcquire! $ref
            } on error e {
                continue
            }
        }

        # This is so that the filename/linenum information in $body is
        # preserved at the caller level.
        upvar __body __body; set __body $body

        set code [catch {uplevel {dict with __result $__body}} \
                      ret opts]

        if {[dict exists $result __ref]} {
            StatementRelease! $ref
        }

        if {$code == 2} {
            # TCL_RETURN: the body did an early return; propagate it
            # to the caller of ForEach!
            return -code return $ret
        } elseif {$code == 1} {
            # TCL_ERROR: an error occurred; preserve the original
            # stack trace.
            return -code error -errorinfo [dict get $opts -errorinfo] $ret
        }
        # code == 0: normal completion; continue to next iteration.
    }
}

set ::thisNode [info hostname]
# TODO: Save ::thisNode and check if it's changed.

if {[__isTracyEnabled]} {
    set tracyCid "tracy_[pid]"
    set ::tracyLib "<C:$tracyCid>"
    set tracySo "/tmp/$tracyCid.so"
    proc tracyCompile {} {tracyCid} {
        # We should only compile this once, then load the same library
        # everywhere in Folk (no matter what thread).
        set tracyCpp [C++]
        $tracyCpp cflags -std=c++20 -I./vendor/tracy/public
        $tracyCpp include <string.h>
        $tracyCpp include "tracy/TracyC.h"
        $tracyCpp proc init {} void {
            fprintf(stderr, "Tracy on\n");
        }
        $tracyCpp proc message {char* x} void {
            TracyCMessage(x, strlen(x));
        }

        $tracyCpp proc frameMark {} void {
            TracyCFrameMark;
        }
        $tracyCpp proc makeString {char* x} uint8_t* {
            return (uint8_t *)strdup(x);
        }
        $tracyCpp proc frameMarkNamed {uint8_t* str} void {
            TracyCFrameMarkNamed((char *)str);
        }
        $tracyCpp proc frameMarkStart {uint8_t* str} void {
            TracyCFrameMarkStart((char *)str);
        }
        $tracyCpp proc frameMarkEnd {uint8_t* str} void {
            TracyCFrameMarkEnd((char *)str);
        }
        $tracyCpp proc plot {uint8_t* str double val} void {
            TracyCPlot((char *)str, val);
        }

        $tracyCpp proc setThreadName {char* name} void {
            TracyCSetThreadName(strdup(name));
        }
        $tracyCpp code {
            __thread TracyCZoneCtx __zoneCtx;
        }
        $tracyCpp proc zoneBegin {} void {
            Jim_Obj* scriptObj = interp->evalFrame->scriptObj;
            const char* sourceFileName;
            int sourceLineNumber;
            if (Jim_ScriptGetSourceFileName(interp, scriptObj, &sourceFileName) != JIM_OK) {
                sourceFileName = "<unknown>";
            }
            if (Jim_ScriptGetSourceLineNumber(interp, scriptObj, &sourceLineNumber) != JIM_OK) {
                sourceLineNumber = -1;
            }
            Jim_CallFrame *frame = interp->framePtr->parent->parent;
            const char *fnName = NULL;
            if (frame != NULL && frame->argv != NULL) {
                fnName = Jim_String(frame->argv[0]);
            }
            uint64_t loc = ___tracy_alloc_srcloc((uint32_t) sourceLineNumber,
                                                 sourceFileName, strlen(sourceFileName),
                                                 fnName != NULL ? fnName : "<unknown>",
                                                 fnName != NULL ? strlen(fnName) : strlen("<unknown>"),
                                                 0);
            __zoneCtx = ___tracy_emit_zone_begin_alloc(loc, 1);
        }
        $tracyCpp proc zoneName {char* name} void {
            ___tracy_emit_zone_name(__zoneCtx, name, strlen(name));
        }
        $tracyCpp proc zoneEnd {} void {
            ___tracy_emit_zone_end(__zoneCtx);
        }
        return [$tracyCpp compile $tracyCid]
    }
    proc tracyTryLoad {} {tracySo} {
        if {![file exists $tracySo]} {
            return false
        }
        $::tracyLib init
        rename ::tracy ""
        rename $::tracyLib ::tracy
        return true
    }

    if {[__threadId] == 0} {
        set tracyTemp [tracyCompile]
        $tracyTemp init
        rename $tracyTemp ::tracy
    } else {
        proc ::tracy {args} {
            # HACK: We pretty much just throw away all tracing calls
            # until tracy is loaded.
            if {[tracyTryLoad]} {
                ::tracy {*}$args
            }
        }
    }

} else {
    proc ::tracy {args} {}
}

signal handle SIGUSR1

# For backward-compatibility:
proc Assert {args} {
    puts stderr "Warning: Assert with no ! is deprecated: trying to [list Assert {*}$args]"
    uplevel Assert! {*}$args
}
set ::isLaptop [expr {$::tcl_platform(os) eq "darwin" ||
                      ([info exists ::env(XDG_SESSION_TYPE)] &&
                       $::env(XDG_SESSION_TYPE) ne "tty")}]
