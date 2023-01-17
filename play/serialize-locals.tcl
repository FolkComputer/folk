proc bloop {} {
    set x 3
    set locals [info locals]
    set localsDict [dict create]
    foreach localName $locals {dict set localsDict $localName [set $localName]}
    puts $localsDict
}

bloop
