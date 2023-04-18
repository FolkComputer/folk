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
vwait good

Assert when we are running {
    puts "Core: $::nodename"
    On process {
        set n 0
        while true {
            incr n
            Commit { Claim the counter is $n }
            Step
        }
    }

    When the counter is /n/ {
        if {$n > 5} {
            set ::done true
        }
    }
}
Step
vwait done
