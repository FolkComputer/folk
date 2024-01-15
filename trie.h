#ifndef TRIE_H
#define TRIE_H

typedef struct Clause {
    int32_t nterms;
    char* terms[];
} Clause;

typedef struct Trie Trie;

// Tries are immutable.

Trie* trieCreate();

// Returns a new Trie pointer with the clause added.
Trie* trieAdd(Trie* trie, Clause* c, uint64_t value);
// TODO: Specify ownership of Clause and term strings inside the
// Clause.

// TODO: Provide a method to emit a graphviz graph.

#endif
