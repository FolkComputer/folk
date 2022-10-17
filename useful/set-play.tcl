namespace eval statementset {
    namespace export create difference
    proc create {args} {
        set kvs [list]
        foreach k $args { lappend kvs $k true }
        dict create {*}$kvs
    }
    proc difference {s t} {
        dict filter $s script {k v} {expr {![dict exists $t $k]}}
    }
    namespace ensemble create
}

set a [statementset create {the time is 6} {Omar is a person}]
set b [statementset create {the time is 7} {Omar is a person}]

puts "a: $a"
puts "b: $b"
puts "a - b: [statementset difference $a $b]"
puts "b - a: [statementset difference $b $a]"

