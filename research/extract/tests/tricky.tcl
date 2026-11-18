# Syntax corner cases for difftest.tcl. Never evaluated, only tokenized.
set a "x [list "nested quote ]" {brace ]}] y"
set b {a}{b}
set c "a"b
set d ${a b}c
set e $::ns::var(idx)$(1 + 2)
set f $ $$ $) ($x) $x) ($x
set g [a [b [c]] "d [e] f" {g [h}]
set h a\ b\
   continued {*}$list {*}{a b} {expand}$old {*}[cmd]
set i "multi
line $x
  [cmd
     arg] end" ;# trailing comment
   # indented comment \
     continued comment
set j {brace with \} escaped and \{ too}
set k "quote with \" escaped and \[ too"
set l a#b #c ; # d
set m \{ \} \" \$x \[y\]
set n ""
set o {}
set p "$x"
set q {*}
set r "a;b
c"
set s [set t "]"]
set u $x(a b)(c)
set v "$fn($arg) and f($x, $y) and $z()"
When /x/ is {*}$p & /y/ is "$q" { puts "$x [expr {$y + 1}]" }
if {$x} {a} else {b}; puts done
