stdout buffering line

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
        tailcall $cmdName {*}$args

    } elseif {[regexp {<library:([^ ]+)>} $cmdName -> tclfile]} {
        # Allow Tcl `library create` libraries to be callable from any
        # thread, because we load the library into the Tcl interpreter
        # for a given thread on demand.
        source $tclfile
        tailcall $cmdName {*}$args

    } else {
        upvar ^$cmdName fn
        if {[info exists fn]} {
            lassign $fn argNames body sourceInfo capturedEnvId
            if {[info source $body] ne $sourceInfo} {
                set body [info source $body {*}$sourceInfo]
            }

            set env [$::envLib get $capturedEnvId]
            if {$env eq ""} { error "Environment invalidated" }
            lassign $env capturedNames capturedValues

            set capturedEnv [dict create]
            foreach name $capturedNames value $capturedValues {
                dict set capturedEnv $name $value
            }

            dict with capturedEnv {
                proc $cmdName $argNames $capturedNames $body
            }
            tailcall $cmdName {*}$args
        }
    }

    tailcall error "Unknown command '$cmdName'"
}

# Set up the global environment store.
set ::envLib [apply {{} {
    set envCid "env_[pid]"
    set envLib "<C:$envCid>"
    set envSo "/tmp/$envCid.so"

    if {[__threadId] != 0} {
        # If not on thread 0, wait for thread 0 to compile envLib,
        # then load it.
        while {![file exists $envSo]} {
            sleep 0.2
        }
        return $envLib
    }

    set cc [C]
    $cc cflags -I.
    $cc include <string.h>
    $cc include <stdatomic.h>
    $cc include "epoch.h"

    $cc code {
        typedef struct Env {
            int _Atomic rc;
            char* _Atomic data;
        } Env;
    }
    # insert can be called from any thread at any time.
    $cc proc insert {char* data} Env* {
        Env *env = malloc(sizeof(Env));
        env->data = strdup(data);
        env->rc = 1;
        return env;
    }
    # update can only be called from the same thread that did the
    # original insert and got that idx.
    $cc proc update {Env* env char* data} void {
        epochBegin();

        char *oldData = env->data;
        char *newData = strdup(data);
        if (atomic_compare_exchange_weak(&env->data,
                                         &oldData, newData)) {
            epochFree(oldData);
        } else {
            // If not, then it must have been removed already.
            FOLK_ENSURE(oldData == NULL);
        }

        epochEnd();
    }
    # get can be called from any thread at any time.
    $cc proc get {Env* env} Jim_Obj* {
        epochBegin();

        // We have to copy the env while still in the epoch to ensure
        // that the env doesn't get invalidated.
        Jim_Obj *ret = Jim_NewStringObj(interp, env->data, -1);

        epochEnd();
        return ret;
    }
    $cc proc incrRefCount {Env* env} void {
        env->rc++;
    }
    $cc proc decrRefCount {Env* env} void {
        if (--env->rc == 0) {
            epochBegin();

            epochFree(env->data);
            epochFree(env);

            epochEnd();
        }
    }
    return [$cc compile $envCid]
}}]

proc captureEnv {} {
    # Capture the lexical environment at the caller, then store it in
    # the environment store.
    set envId [uplevel {
        set locals [info locals]

        set envNames [list]
        set envValues [list]
        # Get all variables and serialize them, to fake lexical scope.
        foreach __name $locals {
            if {![string match "__*" $__name]} {
                lappend envNames $__name
                lappend envValues [set $__name]
            }
        }
        set env [list $envNames $envValues]

        # Put the captured environment into the env store:
        if {[info exists __envId]} {
            # Update env in the environment store.
            $::envLib update $__envId $env
        } else {
            # Insert env into the environment store.
            set __envId [$::envLib insert $env]

            # FIXME: what about when this is called from fn?
            Destructor true [list $::envLib decrRefCount $__envId]
        }

        unset locals envNames envValues env
        set __envId
    }]
    return $envId
}

proc applyBlock {lambdaExpr capturedEnvId args} {
    # Get env from the environment store.
    if {$capturedEnvId ne ""} {
        set env [$::envLib get $capturedEnvId]
        if {$env eq ""} { error "Environment invalidated" }
        lassign $env capturedNames capturedValues
    } else {
        set capturedNames [list]
        set capturedValues [list]
    }

    set names [list]
    foreach capturedName $capturedNames {
        if {[string index $capturedName 0] eq "^"} {
            # Delete any old version of the fn.
            try {
                rename [string index $capturedName 1 end] {}
            } on error e {}
        }
        lappend names $capturedName
    }
    lappend names {*}[lindex $lambdaExpr 0]
    lset lambdaExpr 0 $names

    tailcall apply $lambdaExpr {*}$capturedValues {*}$args
}

proc evaluateWhenBlock {whenLambdaExpr capturedEnvId whenArgValues} {
    try {
        applyBlock $whenLambdaExpr $capturedEnvId {*}$whenArgValues

    } on error {err opts} {
        set errorInfo [dict get $opts -errorinfo]
        set this [lindex $errorInfo 1]
        puts stderr "\nError in $this: $err\n  [errorInfo $err $errorInfo]"
        Say $this has error $err with info $opts
    }
}

proc fn {name argNames body} {
    # Creates a variable in the caller scope called ^$name. Our custom
    # unknown implementation will check ^$name on call.
    set capturedEnvId [uplevel captureEnv]
    uplevel [list set ^$name [list $argNames $body [info source $body] $capturedEnvId]]
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

proc lsort_key_asc {key l} {
    return [lsort -command [list apply {{key a b} {
        expr {[dict get $a $key] < [dict get $b $key]}
    }} $key] $l]
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
}
proc baretime body { string map {" microseconds per iteration" ""} [uplevel [list time $body]] }

proc HoldStatement! {args} {
    set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]

    set key [list]
    set clause [lindex $args end]
    set keepMs 0
    for {set i 0} {$i < [llength $args] - 1} {incr i} {
        set arg [lindex $args $i]
        if {$arg eq "(on"} {
            incr i
            set this [string range [lindex $args $i] 0 end-1]
        } elseif {$arg eq "(keep"} {
            incr i
            set keep [lindex $args $i]
            if {[string match {*ms)} $keep]} {
                set keepMs [string range $keep 0 end-3]
            } else {
                error "HoldStatement!: invalid keep value [string range $keep 0 end-1]"
            }
        } else {
            lappend key $arg
        }
    }
    set key [list $this {*}$key]

    tailcall HoldStatementGlobally! $key $clause $keepMs
}
proc Hold! {args} {
    set body [lindex $args end]
    if {$body eq ""} {
        tailcall HoldStatement! {*}$args
    }

    set isNonCapturing false
    set args [lmap arg [lreplace $args end end] {
        if {$arg eq "(non-capturing)"} {
            set isNonCapturing true; continue
        } else { set arg }
    }]

    if {$isNonCapturing} {
        set envId {}
    } else {
        set envId [uplevel captureEnv]

        $::envLib incrRefCount $envId
        append body "
Destructor true \[list \$::envLib decrRefCount {$envId}]"
    }
    tailcall HoldStatement! {*}$args \
        [list when [list {} $body] with environment $envId]
}
proc Claim {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args }
proc Wish {args} { upvar this this; Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args }
proc When {args} {
    set body [lindex $args end]
    set sourceInfo [info source $body]

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
        set env {}
    } else {
        set env [uplevel captureEnv]
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
            lset pattern $i [uplevel [list subst $term]]
        }
    }

    if {$isNegated} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        tailcall SayWithSource {*}$sourceInfo \
            when the collected matches for $pattern are /__matches/ \
            [list [list __matches] $negateBody] with environment $env
    } else {
        tailcall SayWithSource {*}$sourceInfo \
            when {*}$pattern \
            [list $varNamesWillBeBound $body] with environment $env
    }
}
proc Every {_time args} {
    if {$_time eq "time"} {
        # Set up a When for the outermost match, then query for any
        # inner matches, then unmatch at the end.
        set body [lindex $args end]
        set pattern [lreplace $args end end]
        set andIdx [lsearch $pattern &]
        if {$andIdx != -1} {
            set firstPattern [lrange $pattern 0 $andIdx-1]
            set restPatterns [lrange $pattern $andIdx+1 end]
            set body "set _unmatchRef \[__currentMatchRef]
set __results \[Query! {*}{$restPatterns}]
foreach __result \$__results { dict with __result {
$body
} }
Unmatch! \$_unmatchRef"
        } else {
            set firstPattern $pattern
            set body "set _unmatchRef \[__currentMatchRef]
$body
Unmatch! \$_unmatchRef"
        }
        tailcall When {*}$firstPattern $body
    } else {
        error "Every: Unknown first argument '$_time'"
    }
}

proc On {event args} {
    if {$event eq "unmatch"} {
        set body [lindex $args 0]
        set env [uplevel captureEnv]
        Destructor false [list applyBlock [list {} $body] $env]
    } else {
        error "On: Unknown '$event' (called with: [string range $args 0 50]...)"
    }
}

# Query! is like QuerySimple! but with added support for & joins, and
# it'll automatically also test the claimized pattern (with `/someone/
# claims` prepended).
proc Query! {args} {
    # HACK: this (parsing &s and filling resolved vars) is mostly
    # copy-and-pasted from When.

    # TODO: refactor common logic out? is it worth it?

    set pattern $args
    set varNamesWillBeBound [list]
    for {set i 0} {$i < [llength $args]} {incr i} {
        set term [lindex $args $i]
        if {$term eq "&"} {
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingTerm [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingTerm -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            break

        } elseif {[set varName [__scanVariable $term]] != 0} {
            if {[__variableNameIsNonCapturing $varName]} {
            } elseif {$varName eq "nobody" || $varName eq "nothing"} {
                error "Query!: negation is not supported"

            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }
        } elseif {[__startsWithDollarSign $term]} {
            lset pattern $i [uplevel subst $term]
        }
    }

    if {[llength $pattern] >= 2 && ([lindex $pattern 1] eq "claims" ||
                                    [lindex $pattern 1] eq "wishes")} {
        set results0 [QuerySimple! {*}$pattern]
    } else {
        # If the pattern doesn't already have `claims` or `wishes` in
        # second position, then automatically query for the claimized
        # version of the pattern as well.
        set results0 [concat [QuerySimple! {*}$pattern] \
                          [QuerySimple! /someone/ claims {*}$pattern]]
    }

    if {![info exists remainingPattern]} {
        return $results0
    }

    set results [list]
    foreach result0 $results0 {
        dict with result0 {
            foreach result [Query! {*}$remainingPattern] {
                lappend results [dict merge $result0 $result]
            }
        }
    }
    return $results
}

set ::thisNode [info hostname]

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
            Jim_Obj* scriptObj = interp->currentScriptObj;
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
