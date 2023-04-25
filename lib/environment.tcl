namespace eval ::SerializableEnvironment {}

proc serializeEnvironment {} {
    set env [dict create]
    # get all variables and serialize them
    # (to fake lexical scope)
    foreach name [info vars ::SerializableEnvironment::*] {
        if {![string match "::SerializableEnvironment::__*" $name]} {
            dict set env [namespace tail $name] [set $name]
        }
    }
    foreach importName [namespace eval ::SerializableEnvironment {namespace import}] {
        dict set env %$importName [namespace origin ::SerializableEnvironment::$importName]
    }
    foreach procName [info procs ::SerializableEnvironment::*] {
        if {![dict exists $env %[namespace tail $procName]]} {
            dict set env ^[namespace tail $procName] \
                [list [info args $procName] [info body $procName]]
        }
    }
    set env
}

proc deserializeEnvironment {env} {
    dict for {name value} $env {
        if {[string index $name 0] eq "^"} {
            proc ::SerializableEnvironment::[string range $name 1 end] {*}$value
        } elseif {[string index $name 0] eq "%"} {
            namespace eval ::SerializableEnvironment \
                [list namespace import -force $value]
        } else {
            set ::SerializableEnvironment::$name $value
        }
    }
}

proc isRunningInSerializedEnvironment {} {
    expr {[uplevel {namespace current}] eq "::SerializableEnvironment"}
}

set ::Evaluator::totalTimesMap [dict create]
set ::Evaluator::runsMap [dict create]
variable runsMap
proc runInSerializedEnvironment {body env} {
    dict incr ::Evaluator::runsMap $body
    if {![dict exists $::Evaluator::totalTimesMap $body]} {
        dict set ::Evaluator::totalTimesMap $body [dict create loadTime 0 runTime 0 unloadTime 0]
    }
    set loadTime_ [time {deserializeEnvironment $env}]
    try {
        set runTime_ [time {set ret [namespace eval ::SerializableEnvironment $body]}]
        set ret
    } finally {
        set unloadTime_ [time {
            namespace delete ::SerializableEnvironment
            namespace eval ::SerializableEnvironment {}
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
