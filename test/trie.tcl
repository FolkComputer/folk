set t [trie create]
trie add t {Omar is a person} 1
trie add t {Generic is a /y/} 2

proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

assert {[trie lookup $t {Omar is a person}] eq {1}}
assert {[trie lookup $t {/p/ is a person}] eq {1 2}}
assert {[trie lookup $t {Omar is a /x/}] eq {1}}
assert {[trie lookup $t {Generic is a dog}] eq {2}}

set t2 [trie create]
trie add t2 {a is a x} value1
trie add t2 {a is a y} value2
assert {[trie lookup $t2 {a is a /k/}] eq {value1 value2}}
exec dot -Tpdf <<[ctrie dot $t2] >ctrie.pdf
