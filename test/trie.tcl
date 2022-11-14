set t [trie create]
trie add t {Omar is a person} 1
trie add t {Generic is a /species/} 2

proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

exec dot -Tpdf <<[ctrie dot $t] >ctrie.pdf
assert {[trie lookup $t {Omar is a person}] == {1}}
puts [trie lookup $t {/someone/ is a person}]
assert {[trie lookup $t {/someone/ is a person}] == {1 2}}
assert {[trie lookup $t {Omar is a /species/}] == {1}}
assert {[trie lookup $t {Generic is a dog}] == {2}}
exec dot -Tpdf <<[ctrie dot $t] >ctrie.pdf
