set t [trie create]
trie add t {Omar is a person} 1
trie add t {Generic is a /species/} 2
puts [trie lookup $t {Omar is a person}] ;# should be {1}
puts [trie lookup $t {/someone/ is a person}] ;# should be {1}
puts [trie lookup $t {Omar is a /species/}] ;# should be {1}
puts [trie lookup $t {Generic is a dog}] ;# should be {2}
