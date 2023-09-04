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
    set loadTime_ [baretime {}]

    try {
        set runTime_ [baretime {set ret [apply $lambda {*}$env]}]
        set ::stepRunTime [+ $::stepRunTime $runTime_]
        set ret

    } finally {
        set unloadTime_ [baretime {}]
        dict with ::Evaluator::totalTimesMap $lambda {
            incr loadTime $loadTime_
            if {[info exists runTime_]} {
                incr runTime $runTime_
            }
            incr unloadTime $unloadTime_
        }
    }
}
