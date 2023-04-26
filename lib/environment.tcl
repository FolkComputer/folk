proc serializeEnvironment {} {
    set ns [uplevel {namespace current}]
    if {![string match "::SerializableEnvironment*" $ns]} {
        error "Not running in serializable env in $ns"
    }

    set env [dict create]
    # get all variables and serialize them
    # (to fake lexical scope)
    foreach name [info vars ${ns}::*] {
        if {![string match "${ns}::__*" $name]} {
            dict set env [namespace tail $name] [set $name]
        }
    }
    foreach importName [namespace eval $ns {namespace import}] {
        dict set env %$importName [namespace origin ${ns}::$importName]
    }
    foreach procName [info procs ${ns}::*] {
        if {![dict exists $env %[namespace tail $procName]]} {
            dict set env ^[namespace tail $procName] \
                [list [info args $procName] [info body $procName]]
        }
    }
    set env
}

proc deserializeEnvironment {env ns} {
    dict for {name value} $env {
        if {[string index $name 0] eq "^"} {
            proc ${ns}::[string range $name 1 end] {*}$value
        } elseif {[string index $name 0] eq "%"} {
            namespace eval $ns \
                [list namespace import -force $value]
        } else {
            set ${ns}::$name $value
        }
    }
}

proc isRunningInSerializedEnvironment {} {
    string match "::SerializableEnvironment*" [uplevel {namespace current}]
}

set ::Evaluator::totalTimesMap [dict create]
set ::Evaluator::runsMap [dict create]
set ::Evaluator::nextRunId 0
proc runInSerializedEnvironment {body env} {
    dict incr ::Evaluator::runsMap $body
    if {![dict exists $::Evaluator::totalTimesMap $body]} {
        dict set ::Evaluator::totalTimesMap $body [dict create loadTime 0 runTime 0 unloadTime 0]
    }
    set loadTime_ [time {
        set ns ::SerializableEnvironment[incr ::Evaluator::nextRunId]
        namespace eval $ns {}
        deserializeEnvironment $env $ns
    }]

    try {
        set runTime_ [time {
            set ret [namespace eval $ns $body]
        }]
        set ret
    } finally {
        set unloadTime_ [time {
            namespace delete $ns
        }]
        dict with ::Evaluator::totalTimesMap $body {
            incr loadTime [string map {" microseconds per iteration" ""} $loadTime_]
            if {[info exists runTime_]} {
                incr runTime [string map {" microseconds per iteration" ""} $runTime_]
            }
            incr unloadTime [string map {" microseconds per iteration" ""} $unloadTime_]
        }
    }
}
