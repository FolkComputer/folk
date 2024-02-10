Assert when /someone/ wishes to run program /prog/ {{prog} {
    eval $prog
}} with environment {}

Assert test.tcl wishes to run program {
    When the tick count is /n/ {
        puts "Thread [__threadId]: Tick: $n"
    }

    set n 0
    while true {
        incr n
        Assert the tick count is $n
        Retract the tick count is [expr {$n - 1}]
        sleep 1
    }
}
