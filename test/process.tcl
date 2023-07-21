Assert when we are running {{} {
    On process A {
        puts hello
    }
}}
Assert we are running
Step

Assert when we are running {{} {
    On process Good {
        Claim things are good
    }

    When things are good {
        set ::good true
    }
}}
Step
vwait ::good

Assert when we are running {{} {
    On process Counter {
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
    On process In-a-process {
        Claim I am in a process
        When I am in a process {
            Commit { Claim we were in a process }
        }
    }
    When we were in a process {
        set ::wereinaprocess true
    }
}}
Step
vwait ::wereinaprocess

Assert when we are running {{} {
    On process Receiver {
        Wish $::thisProcess receives statements like [list /x/ claims the main process exists]
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

Retract when we are running /anything/ with environment /e/
Step

Assert when we are running {{} {
    set x done
    On process Python {
        eval [python3 [subst {
            print("Claim Python is $x")
        }]]
    }
    When Python is done {
        set ::pythondone true
    }
}}
Step

vwait ::pythondone

Retract when we are running /anything/ with environment /e/
Step

puts --------------------------

Assert when we are running {{} {
    # FIXME: Test bidirectional sharing/echoing
    
    On process "New counter" {
        set n 0
        forever {
            incr n
            Commit { Claim the counter is $n }
        }
    }
    On process {
        Wish $::thisProcess receives statements like \
            [list /someone/ claims the counter is /n/]
    }

    When the counter is /n/ {
        if {$::stepCount >= 100} {
            puts "Step $::stepCount : $n"
        }
        if {$::stepCount >= 110} {
            exit 0
        }
    }
}}
Step

vwait forever
