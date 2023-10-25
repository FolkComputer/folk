Assert when we are running {{} {
    Start process A {
        puts hello
    }
}}
Assert we are running
Step

Assert when we are running {{} {
    On process A {
        puts whup
    }
}}

for {set i 0} {$i < 1000} {incr i} {
    Step
}
