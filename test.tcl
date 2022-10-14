proc perf {} {
    puts "No additional statements:"
    puts [time Step 100]

    for {set i 0} {$i < 100} {incr i} {
        Assert $i
    }
    puts "100 additional statements:"
    puts [time Step 100]
    puts "100 additional statements:"
    puts [time Step 100]    
}
