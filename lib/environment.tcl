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
    list $argnames $argvalues
}

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
