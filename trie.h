#ifndef TRIE_H
#define TRIE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

typedef struct Term Term;
Term* termNew(const char* s, int len);
int termLen(const Term* t);
const char* termPtr(const Term* t);
bool termEq(const Term* t1, const Term* t2);
bool termEqString(const Term* t, const char* s);

typedef struct Clause {
    int32_t nTerms;
    Term* terms[];
} Clause;
Clause* clauseNew(int32_t nTerms);
Clause* clauseDup(Clause* c);
void clauseFree(Clause* c);
void clauseFreeBorrowed(Clause* c);

// Caller must free the string.
char* clauseToString(Clause* c);

bool clauseIsEqual(Clause* a, Clause* b);

typedef struct Trie Trie;
struct Trie {
    // This term string is owned by the trie.
    Term* key;

    // In practice, we store a statement ref in this slot.
    bool hasValue;
    uint64_t value;

    int32_t branchesCount;
    const Trie* branches[];
};
#define SIZEOF_TRIE(CAPACITY_BRANCHES) (sizeof(Trie) + (CAPACITY_BRANCHES)*sizeof(Trie*))

typedef struct Trie Trie;

const Trie* trieNew();

// The `alloc` parameter is called by the trie functions to
// heap-allocate memory. This is so that you (the caller) can supply a
// custom allocator that can track & later reverse allocations if you
// encounter a conflict that requires a retry (i.e., in a CAS loop).
// 
// The `retire` parameter is called to free any nodes that are being
// replaced when you call `trieAdd` or `trieRemove`. You can pass
// normal `free` if you have no concurrent access; otherwise, you'll
// want to wrap the trie access in some memory reclamation scheme and
// have your `retire` implementation defer reclamation until it's
// guaranteed that no one else is accessing the old trie.

// Returns a new Trie that is like `trie` with `clause` added. Copies
// all the terms in `clause` into trie-owned structures, so the caller
// doesn't need to worry about ownership.
const Trie* trieAdd(const Trie* trie,
                    void *(*alloc)(size_t), void (*retire)(void*),
                    Clause* c, uint64_t value);

// Returns a new Trie that is `trie` with all clauses matching
// `pattern` removed. Fills `results` with the values of all removed
// clauses.
const Trie* trieRemove(const Trie* trie,
                       void *(*alloc)(size_t), void (*retire)(void*),
                       Clause* pattern,
                       uint64_t* results, size_t maxResults,
                       int* resultCount);

// Fills `results` with the values of all clauses matching `pattern`.
int trieLookup(const Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults);

// Only looks for literal matches of `literal` in the trie (does not
// treat /variable/ as a variable). Used to check for an
// already-existing statement whenever a statement is inserted.
int trieLookupLiteral(const Trie* trie, Clause* literal,
                      uint64_t* results, size_t maxResults);

bool trieScanVariable(Term* term, char* outVarName, int sizeOutVarName);
bool trieVariableNameIsNonCapturing(const char* varName);

#endif
