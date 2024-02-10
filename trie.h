#ifndef TRIE_H
#define TRIE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

typedef struct Clause {
    int32_t nTerms;
    char* terms[];
} Clause;
#define SIZEOF_CLAUSE(NTERMS) (sizeof(Clause) + (NTERMS)*sizeof(char*))

// Make a new copy of the original Clause that points to new copies of
// all the term strings inside that Clause.
Clause* clauseDup(Clause* c);

char* clauseToString(Clause* c);

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

// Returns a pointer to a Trie that is trie + the clause. For now, we
// can't guarantee that it doesn't mutate the original trie, so you
// should discard that old pointer. The trie will retain pointers to
// all the term strings in the Clause c, so you must not free those
// terms while the clause is still in the trie. (You can free the
// Clause* itself, though.)
Trie* trieAdd(Trie* trie, Clause* c, uint64_t value);

// Removes all clauses matching `pattern` from `trie`. Fills `results`
// with the values of all removed clauses.
int trieRemove(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults);

// Fills `results` with the values of all clauses matching `pattern`.
int trieLookup(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults);

// Only looks for literal matches of `literal` in the trie (does not
// treat /variable/ as a variable). Used to check for an
// already-existing statement whenever a statement is inserted.
int trieLookupLiteral(Trie* trie, Clause* literal,
                      uint64_t* results, size_t maxResults);

bool trieScanVariable(const char* term,
                      char* outVarName, size_t sizeOutVarName);
bool trieVariableNameIsNonCapturing(const char* varName);

#endif
