Assert when we are running {
    set this T00
    On process A {
        puts hello
    }
}
Assert we are running
Step

after 500 {
    dict for {id stmt} $Statements::statements { puts [statement short $stmt] }

    exit 0
}

vwait forever
