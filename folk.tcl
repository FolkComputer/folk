set ::statements [dict create]

proc Claim {args} {
    dict set ::statements $args true
}
proc When {args} {
    set statement [lreplace $args end end]

    if [dict exists $::statements $statement] {
        set cb [lindex $args end]
        eval $cb
    }
}

Claim the fox is out

When the fox is out {
    puts "Squeak!"
}
