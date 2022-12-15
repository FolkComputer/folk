set t [trie create]
trie add t {Omar is a person} 1
trie add t {Generic is a ?} 2

proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

assert {[trie lookup $t {Omar is a person}] == {1}}
assert {[trie lookup $t {? is a person}] == {1 2}}
assert {[trie lookup $t {Omar is a ?}] == {1}}
assert {[trie lookup $t {Generic is a dog}] == {2}}
exec dot -Tpdf <<[ctrie dot $t] >ctrie.pdf
