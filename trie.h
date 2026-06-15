#ifndef TRIE_H
#define TRIE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

#include "jim.h"

// printf-style helper to build a clause (Jim list of string terms)
// from a format string. Splits the formatted result on spaces. Uses
// the current thread's interp.
Jim_Obj* clauseFormat(const char* fmt, ...);

typedef struct Trie Trie;
struct Trie {
    // Owned by the trie: ref count is incremented when stored and
    // decremented when the node is removed (and no successor takes
    // over the key).
    Jim_Obj* key;

    // In practice, we store a statement ref in this slot.
    bool hasValue;
    uint64_t value;

    int32_t branchesCount;
    const Trie* branches[];
};
#define SIZEOF_TRIE(CAPACITY_BRANCHES) (sizeof(Trie) + (CAPACITY_BRANCHES)*sizeof(Trie*))

const Trie* trieNew();

// Allocator/reclaimer callbacks for trie operations.
//
// `alloc`: allocate a trie node. Supply a custom allocator to track &
// reverse allocations on retry (in a CAS loop).
//
// `retire`: retire a replaced node. Pass normal `free` for
// single-threaded use; for concurrent access wrap in a
// memory-reclamation scheme so reclamation is deferred until no
// reader can reach the old node.
//
// `retireObj`: called when a trie node's key is released (no successor
// holds a reference to it). Pass a wrapper around `Jim_DecrRefCount`
// for single-threaded use; in a concurrent context pass a deferred
// variant so the key outlives any epoch-protected readers.
typedef struct TrieAllocator {
    void *(*alloc)(size_t);
    void  (*retire)(void*);
    void  (*retireObj)(Jim_Obj*);
} TrieAllocator;

// Returns a new Trie that is like `trie` with `clause` added. Holds a
// reference to each term Jim_Obj for as long as the term remains in
// the trie.
const Trie* trieAdd(const Trie* trie,
                    const TrieAllocator* allocator,
                    Jim_Obj* c, uint64_t value);

// Returns a new Trie that is `trie` with all clauses matching
// `pattern` removed. Fills `results` with the values of all removed
// clauses.
const Trie* trieRemove(const Trie* trie,
                       const TrieAllocator* allocator,
                       Jim_Obj* pattern,
                       uint64_t* results, size_t maxResults,
                       int* resultCount);

// Fills `results` with the values of all clauses matching `pattern`.
int trieLookup(const Trie* trie, Jim_Obj* pattern,
               uint64_t* results, size_t maxResults);

// Only looks for literal matches of `literal` in the trie (does not
// treat /variable/ as a variable). Used to check for an
// already-existing statement whenever a statement is inserted.
int trieLookupLiteral(const Trie* trie, Jim_Obj* literal,
                      uint64_t* results, size_t maxResults);

bool trieScanVariable(const char* term,
                      char* outVarName, size_t sizeOutVarName);
bool trieVariableNameIsNonCapturing(const char* varName);

#endif
