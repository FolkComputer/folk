// Plan: we'll use locks for the trie at first, then switch to some
// sort of RCU scheme.

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "trie.h"

char* clauseToString(Clause* c) {
    int totalLength = 0;
    for (int i = 0; i < c->nTerms; i++) {
        totalLength += strlen(c->terms[i]) + 1;
    }
    char* ret; char* s; ret = s = malloc(totalLength);
    for (int i = 0; i < c->nTerms; i++) {
        s += snprintf(s, totalLength - (s - ret), "%s ",
                      c->terms[i]);
    }
    return ret;
}
bool clauseIsEqual(Clause* a, Clause* b) {
    if (a->nTerms != b->nTerms) { return false; }
    for (int32_t i = 0; i < a->nTerms; i++) {
        if (strcmp(a->terms[i], b->terms[i]) != 0) {
            return false;
        }
    }
    return true;
}

Trie* trieNew() {
    size_t size = sizeof(Trie) + 10*sizeof(Trie*);
    Trie* ret = (Trie*) calloc(size, 1);
    *ret = (Trie) {
        .key = NULL,
        .hasValue = false,
        .value = 0,
        .capacityBranches = 10
    };
    return ret;
}

static Trie* trieAddImpl(Trie* trie, int32_t nTerms, char* terms[], uint64_t value) {
    if (nTerms == 0) {
        trie->value = value;
        trie->hasValue = true;
        return trie;
    }
    char* term = terms[0];

    // This is a double-pointer in case we resize a node and want to
    // re-point the trie to the new resized node.
    Trie** match = NULL;

    int j;
    for (j = 0; j < trie->capacityBranches; j++) {
        Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (branch->key == term || strcmp(branch->key, term) == 0) {
            match = &trie->branches[j];
            break;
        }
    }

    if (match == NULL) { // add new branch
        if (j == trie->capacityBranches) {
            // We're out of room; need to grow trie.
            trie = realloc(trie, SIZEOF_TRIE(2*trie->capacityBranches));
            trie->capacityBranches *= 2;
            memset(&trie->branches[j], 0, (trie->capacityBranches/2)*sizeof(Trie*));
        }

        Trie* branch = calloc(SIZEOF_TRIE(10), 1);
        branch->key = strdup(term);
        branch->value = 0;
        branch->hasValue = false;
        branch->capacityBranches = 10;

        // TODO: Want to change trie if branch changes, so it's
        // immutable.
        trie->branches[j] = branch;
        match = &trie->branches[j];
    }

    *match = trieAddImpl(*match, nTerms - 1, terms + 1, value);
    return trie;
}

Trie* trieAdd(Trie* trie, Clause* c, uint64_t value) {
    return trieAddImpl(trie, c->nTerms, c->terms, value);
}


bool trieScanVariable(const char* term, char* outVarName, size_t sizeOutVarName) {
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

static void trieLookupAll(Trie* trie,
                          uint64_t* results, size_t maxResults, int* resultsIdx) {
    if (trie->hasValue) {
        if (*resultsIdx < maxResults) {
            results[(*resultsIdx)++] = trie->value;
        }
    }
    for (int j = 0; j < trie->capacityBranches; j++) {
        if (trie->branches[j] == NULL) { break; }
        trieLookupAll(trie->branches[j],
                      results, maxResults, resultsIdx);
    }
}
// Recursive helper function. This might have too many bells and
// whistles, but it's there so that we only have the lookup logic in
// one place (including implementations of wildcards, variables,
// etc). Returns true if and only if the lookup matched everything in
// the given subtrie (this is used for removal, to know that the
// subtrie can be removed at the caller).
static bool trieLookupImpl(bool doRemove, bool isLiteral,
                           Trie* trie, Clause* pattern, int patternIdx,
                           uint64_t* results, size_t maxResults, int* resultsIdx) {
    int wordc = pattern->nTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
            // TODO: Report that there are more than maxResults
            // results?
            return true;
        }
        return false;
    }

    const char* term = pattern->terms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && trieScanVariable(term, termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    bool subtriesMatched[trie->capacityBranches];
    bool allSubtriesMatched = true;
    for (int j = 0; j < trie->capacityBranches; j++) {
        if (trie->branches[j] == NULL) { break; }

        // Easy cases:
        bool subtrieMatched = false;
        if (trie->branches[j]->key == term || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) { // Is the current lookup term a variable?

            subtrieMatched = trieLookupImpl(doRemove, isLiteral,
                                            trie->branches[j], pattern, patternIdx + 1,
                                            results, maxResults, resultsIdx);

        } else if (termType == TERM_TYPE_REST_VARIABLE) {
            trieLookupAll(trie->branches[j],
                          results, maxResults, resultsIdx);
            subtrieMatched = true;

        } else {
            char keyVarName[100];
            // Is the trie node (we're currently walking) a variable?
            if (!isLiteral && trieScanVariable(trie->branches[j]->key, keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    trieLookupAll(trie->branches[j],
                                  results, maxResults, resultsIdx);
                    subtrieMatched = true;

                } else { // Or is the trie node a normal variable?
                    subtrieMatched = trieLookupImpl(doRemove, isLiteral,
                                                    trie->branches[j], pattern, patternIdx + 1,
                                                    results, maxResults, resultsIdx);
                }
            } else {
                const char *keyString = trie->branches[j]->key;
                const char *termString = term;
                if (strcmp(keyString, termString) == 0) {
                    subtrieMatched = trieLookupImpl(doRemove, isLiteral,
                                                    trie->branches[j], pattern, patternIdx + 1,
                                                    results, maxResults, resultsIdx);
                }
            }
        }

        subtriesMatched[j] = subtrieMatched;
        allSubtriesMatched &= subtrieMatched;
    }

    if (doRemove) {
        // Recopy and compact the branches without the deleted
        // (matched) subtries.
        Trie* newBranches[trie->capacityBranches];
        int newBranchesCount = 0;
        for (int j = 0; j < trie->capacityBranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            if (subtriesMatched[j]) {
                free(trie->branches[j]->key);
                free(trie->branches[j]);
            } else {
                newBranches[newBranchesCount++] = trie->branches[j];
            }
        }
        memset(trie->branches, 0, trie->capacityBranches*sizeof(Trie*));
        memcpy(trie->branches, newBranches, newBranchesCount*sizeof(Trie*));
    }

    return allSubtriesMatched;
}

int trieLookup(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, false, trie, pattern, 0,
                   results, maxResults, &resultCount);
    return resultCount;
}

int trieLookupLiteral(Trie* trie, Clause* pattern,
                      uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, true, trie, pattern, 0,
                   results, maxResults, &resultCount);
    return resultCount;
}

int trieRemove(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(true, false, trie, pattern, 0,
                   results, maxResults, &resultCount);
    return resultCount;
}
