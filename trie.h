#ifndef TRIE_H
#define TRIE_H

typedef struct Clause {
    int32_t nterms;
    const char* terms[];
} Clause;
#define SIZEOF_CLAUSE(NTERMS) (sizeof(Clause) + (NTERMS)*sizeof(char*))

typedef struct Trie Trie;
struct Trie {
    const char* key;

    // We generally store a pointer (for example, to a reaction thunk)
    // in this 64-bit value slot.
    bool hasValue;
    uint64_t value;

    int32_t nbranches;
    Trie* branches[];
};
#define SIZEOF_TRIE(NBRANCHES) (sizeof(Trie) + (NBRANCHES)*sizeof(Trie*))

typedef struct Trie Trie;

// Tries are immutable.

Trie* trieCreate();

// Returns a new Trie pointer with the clause added.
Trie* trieAdd(Trie* trie, Clause* c, uint64_t value);
// TODO: Specify ownership of Clause and term strings inside the
// Clause.

// TODO: Provide a method to emit a graphviz graph.

int trieLookup(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults);

#endif
