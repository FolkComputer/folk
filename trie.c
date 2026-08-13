#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#include "folk-zicl.h"
#include "trie.h"
#include "epoch.h"

Zicl_List* clauseFormat(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);

    char* formatted;
    vasprintf(&formatted, fmt, args);
    va_end(args);

    Zicl_List* list = Zicl_NewList(NULL, 0);

    char* saveptr;
    char* token = strtok_r(formatted, " ", &saveptr);
    while (token != NULL) {
        Zicl_Value tokenValue = ziclNewString(token, -1);
        Zicl_ListAppend(list, tokenValue);
        Zicl_Release(tokenValue);
        token = strtok_r(NULL, " ", &saveptr);
    }

    free(formatted);
    return list;
}

const Trie* trieNew() {
    size_t size = sizeof(Trie);
    Trie* ret = (Trie*) calloc(size, 1);
    *ret = (Trie) {
        .key = NULL,
        .hasValue = false,
        .value = 0,
        .branchesCount = 0
    };
    return ret;
}

// This will return the original trie if the clause is already present
// in it.
static const Trie* trieAddImpl(const Trie* trie,
                               const TrieAllocator* allocator,
                               int32_t nTerms, const Zicl_Value terms[], uint64_t value) {
    if (nTerms == 0) {
        if (trie->hasValue) {
            // This clause is already present.
            return trie;
        }
        Trie* newTrie = allocator->alloc(SIZEOF_TRIE(trie->branchesCount));
        memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
        newTrie->value = value;
        newTrie->hasValue = true;
        allocator->retire((void *)trie);
        return newTrie;
    }
    Zicl_Value term = terms[0];

    // Is there an existing branch that already matches the first
    // term?
    int j;
    for (j = 0; j < trie->branchesCount; j++) {
        const Trie* branch = trie->branches[j];
        if (branch == NULL) {
            fprintf(stderr, "should be unreachable\n");
            abort();
        }

        if (ziclEquals(branch->key, term)) {
            break;
        }
    }

    const Trie* addToBranch;
    Trie* newBranch = NULL;
    if (j == trie->branchesCount) {
        // Need to add a new branch.
        newBranch = allocator->alloc(SIZEOF_TRIE(0));
        Zicl_MakeCrossthread(term);
        newBranch->key = Zicl_Borrow(term);
        newBranch->value = 0;
        newBranch->hasValue = false;
        newBranch->branchesCount = 0;
        addToBranch = newBranch;
    } else {
        addToBranch = trie->branches[j];
    }

    const Trie* addedToBranch =
        trieAddImpl(addToBranch,
                    allocator,
                    nTerms - 1, terms + 1, value);
    if (addedToBranch == addToBranch) {
        // Subtrie was unchanged by the addition (meaning that the
        // clause is already in the trie). Return the original trie.
        if (newBranch != NULL) {
            Zicl_Release(newBranch->key);
            allocator->retire(newBranch);
        }
        return trie;
    }

    // We'll need to allocate a new trie -- how many branches should
    // it have?
    int32_t newBranchesCount = trie->branchesCount;
    if (j == trie->branchesCount) {
        // Need to add a new branch.
        newBranchesCount++;
    }

    Trie* newTrie = allocator->alloc(SIZEOF_TRIE(newBranchesCount));
    memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
    newTrie->branchesCount = newBranchesCount;
    newTrie->branches[j] = addedToBranch;
    allocator->retire((void *)trie);
    return newTrie;
}

// This will return the original trie if the clause is already present
// in it.
const Trie* trieAdd(const Trie* trie,
                    const TrieAllocator* allocator,
                    Zicl_List* clause, uint64_t value) {
    int nTerms = Zicl_ListLength(clause);
    const Zicl_Value* terms = Zicl_ListItems(clause);
    return trieAddImpl(trie, allocator, nTerms, terms, value);
}


bool trieScanVariable(const char* term,
                      char* outVarName, size_t sizeOutVarName) {
    if (term[0] != '/') { return false; }
    int i = 1;
    while (true) {
        if (i - 1 > sizeOutVarName) { return false; }
        if (term[i] == '/') {
            if (term[i + 1] == '\0') {
                outVarName[i - 1] = '\0';
                return true;
            } else {
                return false;
            }
        }
        if (term[i] == '\0') { return false; }
        outVarName[i - 1] = term[i];
        i++;
    }
}
bool trieVariableNameIsNonCapturing(const char* varName) {
    const char* nonCapturingVarNames[] = {
        "someone", "something", "anyone", "anything", "any"
    };
    for (int i = 0; i < sizeof(nonCapturingVarNames)/sizeof(nonCapturingVarNames[0]); i++) {
        if (strcmp(varName, nonCapturingVarNames[i]) == 0) {
            return true;
        }
    }
    return false;
}

static void trieLookupAll(const Trie* trie,
                          uint64_t* results, size_t maxResults,
                          int* resultsIdx) {
    if (trie->hasValue) {
        if (*resultsIdx < maxResults) {
            results[(*resultsIdx)++] = trie->value;
        }
    }
    for (int j = 0; j < trie->branchesCount; j++) {
        trieLookupAll(trie->branches[j],
                      results, maxResults, resultsIdx);
    }
}

static void trieLookupImpl(bool isLiteral,
                           const Trie* trie,
                           int patternNTerms, const Zicl_Value patternTerms[],
                           int patternIdx,
                           uint64_t* results, size_t maxResults,
                           int* resultsIdx) {
    int wordc = patternNTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
            // TODO: Report if there are more than maxResults results?
            return;
        }
        return;
    }

    Zicl_Value term = patternTerms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && trieScanVariable(ziclString(term), termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    for (int j = 0; j < trie->branchesCount; j++) {
        if (Zicl_QuickEquals(trie->branches[j]->key, term) || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) {                 // Is the current lookup term a variable?

            trieLookupImpl(isLiteral, trie->branches[j],
                           patternNTerms, patternTerms, patternIdx + 1,
                           results, maxResults,
                           resultsIdx);

        } else if (termType == TERM_TYPE_REST_VARIABLE) {

            trieLookupAll(trie->branches[j],
                          results, maxResults,
                          resultsIdx);

        } else {
            char keyVarName[100];
            // Is the trie node (we're currently walking) a variable?
            if (!isLiteral && trieScanVariable(ziclString(trie->branches[j]->key),
                                               keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    trieLookupAll(trie->branches[j],
                                  results, maxResults,
                                  resultsIdx);

                } else { // Or is the trie node a normal variable?
                    trieLookupImpl(isLiteral, trie->branches[j],
                                   patternNTerms, patternTerms, patternIdx + 1,
                                   results, maxResults,
                                   resultsIdx);
                }
            } else {
                if (ziclEquals(trie->branches[j]->key, term)) {
                    trieLookupImpl(isLiteral, trie->branches[j],
                                   patternNTerms, patternTerms, patternIdx + 1,
                                   results, maxResults,
                                   resultsIdx);
                }
            }
        }
    }
}

static const Trie* trieRemoveImpl(bool isLiteral,
                                  const Trie* trie,
                                  const TrieAllocator* allocator,
                                  int patternNTerms, const Zicl_Value patternTerms[],
                                  int patternIdx,
                                  uint64_t* results, size_t maxResults,
                                  int* resultsIdx) {
    int wordc = patternNTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
            if (Zicl_AsPtr(trie->key)) allocator->retireValue(Zicl_AsPtr(trie->key));
            allocator->retire((void *)trie);
            return NULL;
        }
        return trie;
    }

    Zicl_Value term = patternTerms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && trieScanVariable(ziclString(term), termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    const Trie* newBranches[trie->branchesCount];
    int newBranchesCount = 0;

    for (int j = 0; j < trie->branchesCount; j++) {
        const Trie* newBranch;
        // Easy cases:
        if (Zicl_QuickEquals(trie->branches[j]->key, term) || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) {                 // Is the current lookup term a variable?

            newBranch = trieRemoveImpl(isLiteral,
                                       trie->branches[j],
                                       allocator,
                                       patternNTerms, patternTerms, patternIdx + 1,
                                       results, maxResults,
                                       resultsIdx);

        } else if (termType == TERM_TYPE_REST_VARIABLE) {
            trieLookupAll(trie->branches[j],
                          results, maxResults,
                          resultsIdx);
            // FIXME: this leaks
            newBranch = NULL;

        } else {
            char keyVarName[100];
            // Is the trie node (we're currently walking) a variable?
            if (!isLiteral && trieScanVariable(ziclString(trie->branches[j]->key),
                                               keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    trieLookupAll(trie->branches[j],
                                  results, maxResults, resultsIdx);
                    // FIXME: this leaks
                    newBranch = NULL;

                } else { // Or is the trie node a normal variable?
                    newBranch = trieRemoveImpl(isLiteral,
                                               trie->branches[j],
                                               allocator,
                                               patternNTerms, patternTerms, patternIdx + 1,
                                               results, maxResults,
                                               resultsIdx);
                }
            } else {
                if (ziclEquals(trie->branches[j]->key, term)) {
                    newBranch = trieRemoveImpl(isLiteral,
                                               trie->branches[j],
                                               allocator,
                                               patternNTerms, patternTerms, patternIdx + 1,
                                               results, maxResults,
                                               resultsIdx);
                } else {
                    newBranch = trie->branches[j];
                }
            }
        }

        if (newBranch != NULL) {
            newBranches[newBranchesCount++] = newBranch;
        }
    }
    if (newBranchesCount == 0) {
        if (Zicl_AsPtr(trie->key)) allocator->retireValue(Zicl_AsPtr(trie->key));
        allocator->retire((void *)trie);
        return NULL;
    }

    Trie* newTrie = allocator->alloc(SIZEOF_TRIE(newBranchesCount));
    memcpy(newTrie, trie, SIZEOF_TRIE(0));
    newTrie->branchesCount = newBranchesCount;
    memcpy(newTrie->branches, newBranches, newBranchesCount*sizeof(Trie*));
    allocator->retire((void *)trie);
    return newTrie;
}

int trieLookup(const Trie* trie, Zicl_List* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    int nTerms = Zicl_ListLength(pattern);
    const Zicl_Value* terms = Zicl_ListItems(pattern);
    trieLookupImpl(false, trie, nTerms, terms, 0,
                   results, maxResults,
                   &resultCount);
    return resultCount;
}

int trieLookupLiteral(const Trie* trie, Zicl_List* pattern,
                      uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    int nTerms = Zicl_ListLength(pattern);
    const Zicl_Value* terms = Zicl_ListItems(pattern);
    trieLookupImpl(true, trie, nTerms, terms, 0,
                   results, maxResults,
                   &resultCount);
    return resultCount;
}

// Note: does _literal_ matching only, for now.
const Trie* trieRemove(const Trie* trie,
                       const TrieAllocator* allocator,
                       Zicl_List* pattern,
                       uint64_t* results, size_t maxResults,
                       int* resultCount) {
    int nTerms = Zicl_ListLength(pattern);
    const Zicl_Value* terms = Zicl_ListItems(pattern);
    return trieRemoveImpl(true, trie,
                          allocator,
                          nTerms, terms, 0,
                          results, maxResults,
                          resultCount);
}
