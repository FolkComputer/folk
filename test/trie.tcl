set t [trie create]
trie add t {Omar is a person} 1
trie add t {Generic is a /y/} 2
trie add t {Cool could be /...anything/} 101

assert {[trie lookup $t {Omar is a person}] eq {1}}
assert {[trie lookup $t {/p/ is a person}] eq {1 2}}
assert {[trie lookup $t {Omar is a /x/}] eq {1}}
assert {[trie lookup $t {Generic is a dog}] eq {2}}

assert {[trie lookup $t {Generic is /...description/}] eq {2}}
assert {[trie lookup $t {/...any/}] eq {1 2 101}}

assert {[trie lookup $t {Cool could be a word}] eq {101}}
assert {[trie lookup $t {Cool could be a noun}] eq {101}}
assert {[trie lookup $t {Cool could be a longer phrase}] eq {101}}

set t2 [trie create]
trie add t2 {a is a x} 101
trie add t2 {a is a y} 102
assert {[trie lookup $t2 {a is a /k/}] eq {101 102}}
exec dot -Tpdf <<[ctrie dot $t2] >ctrie.pdf
