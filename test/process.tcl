Assert when we are running {{} {
    On process A {
        puts hello
    }
}}
Assert we are running
Step

Assert when we are running {{} {
    On process {
        Claim things are good
    }

    When things are good {
        set ::good true
    }
}}
Step
vwait ::good

Assert when we are running {{} {
    On process {
        set n 0
        while true {
            incr n
            Commit { Claim the counter is $n }
            if {$n > 10} { break }
        }
    }

    When the counter is /n/ {
        if {$n > 5} {
            set ::ok true
        }
    }
}}
Step
vwait ::ok

Assert when we are running {{} {
    On process {
        Claim I am in a process
        When I am in a process {
            Commit { Claim we were in a process }
        }
        When we were in a process {
            set ::wereinaprocess true
        }
    }
}}
Step
vwait ::wereinaprocess

Assert when we are running {{} {
    On process {
        Wish $::nodename receives statements like [list /x/ claims the main process exists]
        When the main process exists {
            Commit { Claim the subprocess heard that the main process exists }
        }
    }
    Claim the main process exists
    When the subprocess heard that the main process exists {
        set ::heard true
    }
}}
Step
vwait ::heard
