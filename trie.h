#ifndef TRIE_H
#define TRIE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

typedef struct Clause {
    int32_t nTerms;
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

// TODO: Make tries immutable.

Trie* trieNew();

// Returns a new Trie pointer with the clause added. For now, we can't
// guarantee that it doesn't mutate the original trie.
Trie* trieAdd(Trie* trie, Clause* c, uint64_t value);
// TODO: Specify ownership of Clause and term strings inside the
// Clause.

// TODO: Provide a method to emit a graphviz graph.

int trieLookup(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults);

// Only looks for literal matches of `literal` in the trie (does not
// treat /variable/ as a variable). Used to check for an
// already-existing statement whenever a statement is inserted.
int trieLookupLiteral(Trie* trie, Clause* literal,
                      uint64_t* results, size_t maxResults);

#endif
