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

# Should reset each frame:
proc resetTimers {} {
    set ::Evaluator::stepRunTime 0
    set ::Evaluator::runCountsMap [dict create]
    set ::Evaluator::runTimesMap [dict create]
}
resetTimers

proc runInSerializedEnvironment {lambda env} {
    dict incr ::Evaluator::runCountsMap $lambda

    set runTime [baretime {set ret [apply $lambda {*}$env]}]
    dict set ::Evaluator::runTimesMap $lambda \
        [+ [dict_getdef $::Evaluator::runTimesMap $lambda 0] \
             $runTime]
    set ::Evaluator::stepRunTime [+ $::Evaluator::stepRunTime $runTime]
    return $ret
}
