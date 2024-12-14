#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "trie.h"

Clause* clauseDup(Clause* c) {
    Clause* ret = malloc(SIZEOF_CLAUSE(c->nTerms));
    ret->nTerms = c->nTerms;
    for (int i = 0; i < c->nTerms; i++) {
        ret->terms[i] = strdup(c->terms[i]);
    }
    return ret;
}
void clauseFree(Clause* c) {
    for (int i = 0; i < c->nTerms; i++) {
        free(c->terms[i]);
    }
    free(c);
}

char* clauseToString(Clause* c) {
    if (c == NULL || c->nTerms <= 0 || c->nTerms > 100) {
        return strdup("<invalid clause>");
    }

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

static char *trieStrdup(void *(*alloc)(size_t), char *s0) {
    int sz = strlen(s0) + 1;
    char *s = alloc(sz);
    memcpy(s, s0, sz);
    return s;
}

// This will return the original trie if the clause is already present
// in it.
static const Trie* trieAddImpl(const Trie* trie,
                               void *(*alloc)(size_t), void (*retire)(void*),
                               int32_t nTerms, char* terms[], uint64_t value) {
    if (nTerms == 0) {
        if (trie->hasValue) {
            // This clause is already present.
            return trie;
        }
        Trie* newTrie = alloc(SIZEOF_TRIE(trie->branchesCount));
        memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
        newTrie->value = value;
        newTrie->hasValue = true;
        retire(trie);
        return newTrie;
    }
    char* term = terms[0];

    // Is there an existing branch that already matches the first
    // term?
    int j;
    for (j = 0; j < trie->branchesCount; j++) {
        const Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (branch->key == term || strcmp(branch->key, term) == 0) {
            break;
        }
    }

    const Trie* addToBranch;
    Trie* newBranch = NULL;
    if (j == trie->branchesCount) {
        // Need to add a new branch.
        newBranch = alloc(SIZEOF_TRIE(0));
        newBranch->key = trieStrdup(alloc, term);
        newBranch->value = 0;
        newBranch->hasValue = false;
        newBranch->branchesCount = 0;
        addToBranch = newBranch;
    } else {
        addToBranch = trie->branches[j];
    }

    const Trie* addedToBranch =
        trieAddImpl(addToBranch,
                    alloc, retire,
                    nTerms - 1, terms + 1, value);
    if (addedToBranch == addToBranch) {
        // Subtrie was unchanged by the addition (meaning that the
        // clause is already in the trie). Return the original trie.
        if (newBranch != NULL) {
            retire(newBranch);
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

    Trie* newTrie = alloc(SIZEOF_TRIE(newBranchesCount));
    memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
    newTrie->branchesCount = newBranchesCount;
    newTrie->branches[j] = addedToBranch;
    retire(trie);
    return newTrie;
}

// This will return the original trie if the clause is already present
// in it.
const Trie* trieAdd(const Trie* trie,
                    void *(*alloc)(size_t), void (*retire)(void*),
                    Clause* c, uint64_t value) {
    /* fprintf(stderr, "trieAdd: (%s)\n", clauseToString(c)); */
    const Trie* ret = trieAddImpl(trie, alloc, retire,
                                  c->nTerms, c->terms, value);
    return ret;
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
                           const Trie* trie, Clause* pattern, int patternIdx,
                           uint64_t* results, size_t maxResults,
                           int* resultsIdx) {
    int wordc = pattern->nTerms - patternIdx;
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

    const char* term = pattern->terms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && trieScanVariable(term, termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    for (int j = 0; j < trie->branchesCount; j++) {
        if (trie->branches[j]->key == term || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) { // Is the current lookup term a variable?

            trieLookupImpl(isLiteral, trie->branches[j],
                           pattern, patternIdx + 1,
                           results, maxResults,
                           resultsIdx);

        } else if (termType == TERM_TYPE_REST_VARIABLE) {

            trieLookupAll(trie->branches[j],
                          results, maxResults,
                          resultsIdx);

        } else {
            char keyVarName[100];
            // Is the trie node (we're currently walking) a variable?
            if (!isLiteral && trieScanVariable(trie->branches[j]->key, keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    trieLookupAll(trie->branches[j],
                                  results, maxResults,
                                  resultsIdx);

                } else { // Or is the trie node a normal variable?
                    trieLookupImpl(isLiteral, trie->branches[j],
                                   pattern, patternIdx + 1,
                                   results, maxResults,
                                   resultsIdx);
                }
            } else {
                const char *keyString = trie->branches[j]->key;
                const char *termString = term;
                if (strcmp(keyString, termString) == 0) {
                    trieLookupImpl(isLiteral, trie->branches[j],
                                   pattern, patternIdx + 1,
                                   results, maxResults,
                                   resultsIdx);
                }
            }
        }
    }
}

static const Trie* trieRemoveImpl(bool isLiteral,
                                  const Trie* trie,
                                  void *(*alloc)(size_t), void (*retire)(void*),
                                  Clause* pattern, int patternIdx,
                                  uint64_t* results, size_t maxResults,
                                  int* resultsIdx) {
    int wordc = pattern->nTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
            if (trie->key != NULL) {
                retire(trie->key);
            }
            retire(trie);
            return NULL;
        }
        return trie;
    }

    const char* term = pattern->terms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && trieScanVariable(term, termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    const Trie* newBranches[trie->branchesCount];
    int newBranchesCount = 0;

    for (int j = 0; j < trie->branchesCount; j++) {
        const Trie* newBranch;
        // Easy cases:
        if (trie->branches[j]->key == term || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) { // Is the current lookup term a variable?

            newBranch = trieRemoveImpl(isLiteral,
                                       trie->branches[j],
                                       alloc, retire,
                                       pattern, patternIdx + 1,
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
            if (!isLiteral && trieScanVariable(trie->branches[j]->key, keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    trieLookupAll(trie->branches[j],
                                  results, maxResults, resultsIdx);
                    // FIXME: this leaks
                    newBranch = NULL;

                } else { // Or is the trie node a normal variable?
                    newBranch = trieRemoveImpl(isLiteral,
                                               trie->branches[j],
                                               alloc, retire,
                                               pattern, patternIdx + 1,
                                               results, maxResults,
                                               resultsIdx);
                }
            } else {
                const char *keyString = trie->branches[j]->key;
                const char *termString = term;
                if (strcmp(keyString, termString) == 0) {
                    newBranch = trieRemoveImpl(isLiteral,
                                               trie->branches[j],
                                               alloc, retire,
                                               pattern, patternIdx + 1,
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
        if (trie->key != NULL) {
            retire(trie->key);
        }
        retire(trie);
        return NULL;
    }

    Trie* newTrie = alloc(SIZEOF_TRIE(newBranchesCount));
    memcpy(newTrie, trie, SIZEOF_TRIE(0));
    newTrie->branchesCount = newBranchesCount;
    memcpy(newTrie->branches, newBranches, newBranchesCount*sizeof(Trie*));
    retire(trie);
    return newTrie;
}

int trieLookup(const Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, trie, pattern, 0,
                   results, maxResults,
                   &resultCount);
    /* fprintf(stderr, "trieLookup: (%s) -> %d\n", clauseToString(pattern), resultCount); */
    return resultCount;
}

int trieLookupLiteral(const Trie* trie, Clause* pattern,
                      uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(true, trie, pattern, 0,
                   results, maxResults,
                   &resultCount);
    return resultCount;
}

// Note: does _literal_ matching only, for now.
const Trie* trieRemove(const Trie* trie,
                       void *(*alloc)(size_t), void (*retire)(void*),
                       Clause* pattern,
                       uint64_t* results, size_t maxResults,
                       int* resultCount) {
    return trieRemoveImpl(true, trie,
                          alloc, retire,
                          pattern, 0,
                          results, maxResults,
                          resultCount);
}
