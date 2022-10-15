proc perf {} {
    puts "$::nodename: No additional statements:"
    puts [time Step 100]

    for {set i 0} {$i < 100} {incr i} {
        Assert $i
    }
    puts "$::nodename: 100 additional statements:"
    puts [time Step 100]
    puts "$::nodename: 100 additional statements:"
    puts [time Step 100]    
}
