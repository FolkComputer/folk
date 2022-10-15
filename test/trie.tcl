set t [trie create]
trie add t {Omar is a person} 1
puts [trie lookup $t {Omar is a person}] ;# should be {1}
puts [trie lookup $t {/someone/ is a person}] ;# should be {1}
