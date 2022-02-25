set ::statements [dict create]

proc Claim {args} {
    dict set ::statements $args true
}
proc When {args} {
    
}

Claim the fox is out

puts [dict size $::statements]
puts $::statements

When the fox is out {
    
}
