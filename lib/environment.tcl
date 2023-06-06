namespace eval ::SerializableEnvironment {}

proc serializeEnvironment {} {
    set argnames [list]
    set argvalues [list]
    # Get all variables and serialize them, to fake lexical scope.
    foreach name [uplevel {info locals}] {
        if {![string match "__*" $name]} {
            lappend argnames $name
            lappend argvalues [uplevel [list set $name]]
        }
    }
    # foreach importName [namespace eval ::SerializableEnvironment {namespace import}] {
    #     dict set env %$importName [namespace origin ::SerializableEnvironment::$importName]
    # }
    # foreach procName [info procs ::SerializableEnvironment::*] {
    #     if {![dict exists $env %[namespace tail $procName]]} {
    #         dict set env ^[namespace tail $procName] \
    #             [list [info args $procName] [info body $procName]]
    #     }
    # }
    list $argnames $argvalues
}

# proc deserializeEnvironment {env} {
#     dict for {name value} $env {
#         if {[string index $name 0] eq "^"} {
#             proc ::SerializableEnvironment::[string range $name 1 end] {*}$value
#         } elseif {[string index $name 0] eq "%"} {
#             namespace eval ::SerializableEnvironment \
#                 [list namespace import -force $value]
#         } else {
#             set ::SerializableEnvironment::$name $value
#         }
#     }
# }

set ::Evaluator::totalTimesMap [dict create]
set ::Evaluator::runsMap [dict create]

proc runInSerializedEnvironment {lambda env} {
    dict incr ::Evaluator::runsMap $lambda
    if {![dict exists $::Evaluator::totalTimesMap $lambda]} {
        dict set ::Evaluator::totalTimesMap $lambda [dict create loadTime 0 runTime 0 unloadTime 0]
    }
    set loadTime_ [time {}]

    try {
        set runTime_ [time {set ret [apply $lambda {*}$env]}]
        set ret

    } finally {
        set unloadTime_ [time {}]
        dict with ::Evaluator::totalTimesMap $lambda {
            incr loadTime [string map {" microseconds per iteration" ""} $loadTime_]
            if {[info exists runTime_]} {
                incr runTime [string map {" microseconds per iteration" ""} $runTime_]
            }
            incr unloadTime [string map {" microseconds per iteration" ""} $unloadTime_]
        }
    }
}
