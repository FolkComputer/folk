Assert tag 2 has name Omar
Assert tag 3 has name Andres
Step

Retract tag 2 has name Omar
Retract tag 3 has name Andres
Step

exec dot -Tpdf >trie.pdf <<[trie dot $Statements::statementClauseToId]
