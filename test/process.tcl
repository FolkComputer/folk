Assert when we are running {
    On process A {
        puts hello
    }
}
Assert we are running
Step

Assert when we are running {
    On process {
        Assert <root> claims things are good
        Step
    }

    When things are good {
        set ::good true
    }
}
Step
vwait ::good

Assert when we are running {
    puts "Core: $::nodename"
    On process {
        set n 0
        while true {
            incr n
            Commit { Claim the counter is $n }
            Step
            if {$n > 10} { break }
        }
    }

    When the counter is /n/ {
        if {$n > 5} {
            set ::ok true
        }
    }
}
Step
vwait ::ok

Assert when we are running {
    On process {
        Claim I am in a process
        When I am in a process {
            Commit { Claim we were in a process }
        }
        When we were in a process {
            set ::wereinaprocess true
        }
    }
}
Step
vwait ::wereinaprocess
