# HACK: not always linux
set tcl_platform::os linux

# This file gets re-evaluated on every new Tcl interpreter that spins
# up, so multiple times, possibly in parallel, possibly even late in
# the lifetime of the Folk system.
#
# It's sort of the only place you can create genuine globals that you
# can guarantee will be available on any Folk process/block.
lappend auto_path "./vendor"
source "lib/c.tcl"
source "lib/math.tcl"
source "lib/text.tcl"

set folkPid [pid]

# FIXME: zicl doesn't have channel handles like Jimtcl. Re-enable
# buffering configuration when I/O is properly set up.
# $realStdout buffering line
# $realStderr buffering none
# stdout buffering line

set __exec $exec
fn exec {args} {
    # For background exec (ending with &), redirect stdout and stderr
    # to the current thread-local output files so the subprocess's
    # output lands in the right per-program /tmp/ file.
    if {[lindex $args end] eq "&"} {
        if {[info exists ::_folk_localStdout] && [info exists ::_folk_localStderr]} {
            set hasStdout [lsearch -regexp $args {^>@}]
            set hasStderr [lsearch -regexp $args {^2>@}]
            set insertions {}
            if {$hasStdout == -1} { lappend insertions >@ $::_folk_localStdout }
            if {$hasStderr == -1} { lappend insertions 2>@ $::_folk_localStderr }
            set args [lreplace $args end end {*}$insertions &]
        }
    } else {
        # For non-background exec, replace >@stdout / 2>@stderr with
        # the thread-local output channels so subprocess output lands
        # in the right per-program /tmp/ file.
        if {[info exists ::_folk_localStdout]} {
            set i [lsearch -exact $args {>@stdout}]
            if {$i != -1} { set args [lreplace $args $i $i >@ $::_folk_localStdout] }
        }
        if {[info exists ::_folk_localStderr]} {
            set i [lsearch -exact $args {2>@stderr}]
            if {$i != -1} { set args [lreplace $args $i $i 2>@ $::_folk_localStderr] }
        }
    }
    tailcall __exec {*}$args
}

fn applyBlock {body envStack} {
    set env [dict merge {*}$envStack]

    dict set env __envStack $envStack
    dict set env __env $env

    set newThis [dict getdef $env this <unknown>]
    if {![info exists ::this] || $newThis ne $::this} {
        # Flush before switching so any buffered data from the previous
        # program drains to the correct fd before we switch.
        if {[info exists ::this]} { stdout flush }
        set ::this $newThis
        # Install thread-local stdout/stderr so all subsequent write()/puts/
        # fprintf/printf calls go to the local files for this $this.
        __installLocalStdoutAndStderr $::this
    }

    set names [dict keys $env]
    set values [dict values $env]
    tailcall apply [list $names $body] {*}$values
}

fn assert condition {
    if {![uplevel [list expr $condition]]} {
        return -code error "assertion failed: $condition"
    }
}
fn baretime {body} {
    string map {" microseconds per iteration" ""} [uplevel [list time $body]]
}

fn Hold! {args} {
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
    if {[llength $clause] == 1 && [lindex $clause 0] eq ""} {
        set clause ""
    } elseif {[llength $clause] == 1} {
        # Hold! { ... body ... }
        set body [lindex $clause 0]

        lassign [info source $body] filename lineno
        set clause [list when [fn {} $body]]
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

fn Say {args} {
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
            set handler [lindex $args $($i+1)]
            lset args $($i+1) [list applyBlock $handler {}]
        }
    }
    tailcall SayWithSource $sourceFileName $sourceLineNumber \
        $keepMs \
        $atomicallyVersion \
        $destructorCode \
        {*}$pattern
}
fn Claim {args} { upvar this this; tailcall Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args }
fn Wish {args} { upvar this this; tailcall Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args }
# returns the statement to Say/Assert (minus the envStack), as well as all bound variable names
# Returns the front of the clause to Say/Assert (everything up to but not
# including the body), the body script to build the block closure from, and
# the list of variable names that will be bound to it, in the exact order
# clauseUnify will bind them at match time.
fn desugarWhen {pattern body} {
    set varNamesWillBeBound [list]
    set isNegated false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set term [lindex $pattern $i]
        if {$term eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $($i+1) end]
            set pattern [lrange $pattern 0 $($i-1)]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingTerm [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingTerm -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            set body [list When {*}$remainingPattern $body]
            break

        } elseif {[set varName [__scanVariable $term]] ne "false"} {
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
        # The outer pattern here only ever binds /__results/ -- $pattern is
        # spliced in as a single already-built term (collect.folk's
        # Recollect! ran the pre-negation pattern as a query to build it),
        # not scanned for its own variables at this level. The body only
        # runs when $__results is empty, so there's no candidate match left
        # to pull any of the other pattern's variables' values from anyway.
        set negateBody [list if {[llength $__results] == 0} $body]
        return [list \
            [list when the collected results for $pattern are /__results/] \
            $negateBody {__results}]
    } else {
        return [list \
            [list when {*}$pattern] \
            $body $varNamesWillBeBound]
    }
}
fn When {args} {
    upvar this this

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
            # Defer key construction until after the loop so the key
            # uses the full pattern, not just the terms parsed before
            # `-atomically` appeared.
            set atomicallyVersion "fresh-from-full-pattern"
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

    if {$atomicallyVersion eq "fresh-from-full-pattern"} {
        set key [list [uplevel set this] $sourceInfo $pattern]
        set atomicallyVersion [list "fresh" $key]
    }

    if {$atomicallyVersion eq "default"} {
        set inheritAtomicallyVersion [__currentAtomicallyVersion]
        if {$inheritAtomicallyVersion eq {}} {
            # HACK: Default atomically on certain patterns:
            if {([lrange $pattern 1 end-1] eq {has camera slice} ||
                 [lrange $pattern 0 end-1] eq {the clock time is})} {

                set key [list $this $sourceInfo $pattern]
                set atomicallyVersion [list "fresh" $key]
            } else {
                set atomicallyVersion {}
            }
        } else {
            set atomicallyVersion $inheritAtomicallyVersion
        }
    }

    # TODO: -noncapturing isn't wired up to anything yet (it wasn't in the
    # pre-port code either -- both branches just produced an empty
    # envStack). With real closures, the natural meaning would be building
    # the closure with no captured scope.

    if {$isSerially} {
        # Serial prologue: find this When itself; see if that
        # statement ref has any match children that are incomplete. If
        # so, then die.
        # Kept on one line and joined with `;` (not a newline) so that
        # prepending it doesn't shift every line number in $body.
        set prologue {if {[__whenOfCurrentMatchIncompleteChildMatchesCount] > 1} { return }}
        set body "$prologue;$body"
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

    lassign [desugarWhen $pattern $body] clauseFront bodyToWrap boundVars

    # Build the closure one level up, in our caller's frame -- not here in
    # When's own frame, which only has our own parsing internals (pattern,
    # term, i, ...), and not desugarWhen's frame either, which is already
    # gone by the time we get its return value. `fn` captures whatever's
    # actually in scope where the `When {...}` call was written (this, any
    # outer fns), and boundVars becomes its formal parameter list --
    # clauseUnify binds exactly those names, in this order, on every match,
    # so the C side just calls this same closure directly with the bound
    # values on every match. Output redirection (this used to be installed
    # generically by applyBlock from the merged environment) is now handled
    # by runBlock in C, reading `this` straight out of the closure's own
    # captured scope.
    #
    # `list` stringifies the body and `uplevel` re-parses it, which throws
    # away the Source objects carrying the body's file and line. Tracebacks
    # are built from those, so without re-stamping, every error inside a
    # When block reports an empty file name and a line counted from 1 rather
    # than from the top of the file. `list` puts everything ahead of the
    # body on a single line, so the body still starts on line 0 of this
    # script, exactly where it started in the original -- which means
    # $sourceInfo applies unchanged.
    set closure [uplevel 1 [info source [list fn $boundVars $bodyToWrap] {*}$sourceInfo]]

    tailcall SayWithSource {*}$sourceInfo \
        0 $atomicallyVersion {} \
        {*}$clauseFront $closure
}
fn Subscribe: {args} {
    set pattern [lrange $args 0 end-1]
    set body [lindex $args end]

    set sourceInfo [info source $body]

    tailcall SayWithSource {*}$sourceInfo \
        0 {} {} \
        subscribe {*}$pattern $body
}
fn Notify: {args} {
    NotifyImpl {*}$args
}
fn On {event fn} {
    if {$event eq "unmatch"} {
        Destructor [list apply $fn]
    } else {
        error "On: Unknown '$event' (called with: [string range $args 0 50]...)"
    }
}

# Synchronous, sampling query of the db. Returns a list of dicts where
# each dict is a statement matching the pattern.
#
# Query! is like QuerySimple! but with added support for & joins, and
# it'll automatically also query the claimized pattern (the pattern
# with `/someone/ claims` prepended).
fn Query! {args} {
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
            set remainingPattern [lrange $args $($i+1) end]
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

        } elseif {[set varName [__scanVariable $term]] ne "false"} {
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

# Synchronous, sampling query of the db. Throws unless there is
# exactly 1 statement result. Returns a dict whose keys are bound keys
# from the pattern and whose values are corresponding terms from the
# statement.
#
# Use like this:
#
#    Claim the dog is cool
#    sleep 0.5
#    puts [dict get [QueryOne! the dog is /val/] val] ;# -> cool
#
fn QueryOne! {args} {
    set pattern [list]
    for {set i 0} {$i < [llength $args]} {incr i} {
        set arg [lindex $args $i]
        if {$arg eq "-default"} {
            incr i
            set default [lindex $args $i]
        } else {
            lappend pattern $arg
        }
    }

    set results [Query! {*}$pattern]
    if {[llength $results] == 0 && [info exists default]} {
        return $default
    }
    if {[llength $results] != 1} {
        error "QueryOne! of ($args) had [llength $results] results. Should be one result!"
    }

    if {{/./} in $pattern} {
        return [dict get [lindex $results 0] .]
    }
    return [lindex $results 0]
}

# Sort of like QueryOne!, but introduces the bindings directly into
# caller scope. Unlike Expect!, this samples the db once and errors
# unless there is exactly one result.
fn Require! {args} {
    dict for {k v} [QueryOne! {*}$args] {
        uplevel 1 [list set $k $v]
    }
}

# Sort of like QueryOne!, but picks an arbitrary result if >1 result,
# and introduces the bindings directly into caller scope.
#
#     Expect! the dog is /val/
#     puts $val ;# -> cool
#
# Also polls and retries if there are 0 results.
fn Expect! {args} {
    set results [list]
    while {[llength $results] == 0} {
        set results [Query! {*}$args]
        if {[llength $results] == 0} {
            sleep 0.1
        }
    }

    dict for {k v} [lindex $results 0] {
        uplevel 1 [list set $k $v]
    }
}
fn ForEach! {args} {
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
    set tracyCid "tracy_$folkPid"
    set ::tracyLib "<C:$tracyCid>"
    set tracySo "/tmp/$tracyCid.so"
    fn tracyCompile {} {
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
            #define __ZONE_CTX_MAX 16
            __thread TracyCZoneCtx __zoneCtxs[__ZONE_CTX_MAX];
            __thread int __zoneCtxIdx;
        }
        $tracyCpp proc zoneBegin {} void {
            Zicl_Value script = Zicl_GetScriptBeingEvaluated(interp);
            const char* sourceFileName = Zicl_SourceGetFilename(script);
            sourceFileName = sourceFileName ? sourceFileName : "<unknown>";
            Zicl_OptionalValue fnName = Zicl_GetClosureNameBeingEvaluated(interp);
            const char *fnName = "<unknown>";
            if (Zicl_IsSome(fnName)) {
                fnName = ziclString(Zicl_Unwrap(fnName));
            }
            uint64_t loc = ___tracy_alloc_srcloc((uint32_t) sourceLineNumber,
                                                 sourceFileName, strlen(sourceFileName),
                                                 fnName, strlen(fnName), 0);
            if (__zoneCtxIdx >= __ZONE_CTX_MAX) {
                fprintf(stderr, "tracy: zone stack overflow (max %d)\n", __ZONE_CTX_MAX);
                exit(1);
            }
            __zoneCtxs[__zoneCtxIdx++] = ___tracy_emit_zone_begin_alloc(loc, 1);
        }
        $tracyCpp proc zoneName {char* name} void {
            if (__zoneCtxIdx > 0) {
                ___tracy_emit_zone_name(__zoneCtxs[__zoneCtxIdx - 1], name, strlen(name));
            }
        }
        $tracyCpp proc zoneEnd {} void {
            if (__zoneCtxIdx <= 0) {
                fprintf(stderr, "tracy: zone stack underflow\n");
                exit(1);
            }
            ___tracy_emit_zone_end(__zoneCtxs[--__zoneCtxIdx]);
        }
        return [$tracyCpp compile $tracyCid]
    }
    fn tracyTryLoad {} {
        if {![file exists $tracySo]} {
            return false
        }
        $::tracyLib init
        unset ::tracy
        set ::tracy $::tracyLib
        return true
    }

    if {[__threadId] == 0} {
        set tracyTemp [tracyCompile]
        $tracyTemp init
        set ::tracy $tracyTemp
    } else {
        fn ::tracy {args} {
            # HACK: We pretty much just throw away all tracing calls
            # until tracy is loaded.
            if {[tracyTryLoad]} {
                ::tracy {*}$args
            }
        }
    }

} else {
    fn ::tracy {args} {}
}

# FIXME: zicl doesn't have [signal] yet.
# signal handle SIGUSR1

source "lib/python.tcl"

set isLaptop [expr {$tcl_platform::os eq "darwin" ||
                      ([info exists env::XDG_SESSION_TYPE] &&
                       $env::XDG_SESSION_TYPE ne "tty")}]
