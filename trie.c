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

static const Trie* trieAddImpl(const Trie* trie, int32_t nTerms, char* terms[], uint64_t value) {
    if (nTerms == 0) {
        Trie* newTrie = calloc(SIZEOF_TRIE(trie->branchesCount), 1);
        memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
        newTrie->value = value;
        newTrie->hasValue = true;
        return newTrie;
    }
    char* term = terms[0];

    const Trie* addToBranch = NULL;

    // Is there an existing branch that already matches the first
    // term?
    int j;
    for (j = 0; j < trie->branchesCount; j++) {
        const Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (branch->key == term || strcmp(branch->key, term) == 0) {
            addToBranch = trie->branches[j];
            break;
        }
    }

    // We'll need to allocate a new trie no matter what -- how many
    // branches should it have?
    int32_t newBranchesCount = trie->branchesCount;
    if (addToBranch == NULL) { 
        // Need to add a new branch.
        newBranchesCount++;
        j = newBranchesCount - 1;
    }

    Trie* newTrie = calloc(SIZEOF_TRIE(newBranchesCount), 1);
    memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
    newTrie->branchesCount = newBranchesCount;

    if (addToBranch == NULL) { 
        Trie* newBranch = calloc(SIZEOF_TRIE(0), 1);
        newBranch->key = strdup(term);
        newBranch->value = 0;
        newBranch->hasValue = false;
        newBranch->branchesCount = 0;
        addToBranch = newBranch;
    }

    newTrie->branches[j] = trieAddImpl(addToBranch, nTerms - 1, terms + 1, value);
    return newTrie;
}

const Trie* trieAdd(const Trie* trie, Clause* c, uint64_t value) {
    /* fprintf(stderr, "trieAdd: (%s)\n", clauseToString(c)); */
    const Trie* ret = trieAddImpl(trie, c->nTerms, c->terms, value);
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
// Recursive helper function. This might have too many bells and
// whistles, but it's there so that we only have the lookup logic in
// one place (including implementations of wildcards, variables,
// etc). The returned bool `didMatchAllBranches` is used for removal,
// to know that the subtrie can be removed at the caller.
static const Trie* trieLookupImpl(bool doRemove, bool isLiteral,
                                  const Trie* trie, Clause* pattern, int patternIdx,
                                  uint64_t* results, size_t maxResults,
                                  int* resultsIdx, bool* didMatchAllSubtries) {
    int wordc = pattern->nTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
            // TODO: Report if there are more than maxResults results?
            *didMatchAllSubtries = true;
            return trie;
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

    bool mustMakeNewTrie = false;
    const Trie* newBranches[trie->branchesCount];
    int newBranchesCount = 0;

    bool allSubtriesMatched = true;
    for (int j = 0; j < trie->branchesCount; j++) {
        const Trie* newBranch = trie->branches[j];
        // Easy cases:
        bool subtrieMatched = false;
        if (trie->branches[j]->key == term || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) { // Is the current lookup term a variable?

            newBranch = trieLookupImpl(doRemove, isLiteral,
                                       trie->branches[j], pattern, patternIdx + 1,
                                       results, maxResults,
                                       resultsIdx, &subtrieMatched);

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
                    newBranch = trieLookupImpl(doRemove, isLiteral,
                                               trie->branches[j], pattern, patternIdx + 1,
                                               results, maxResults,
                                               resultsIdx, &subtrieMatched);
                }
            } else {
                const char *keyString = trie->branches[j]->key;
                const char *termString = term;
                if (strcmp(keyString, termString) == 0) {
                    newBranch = trieLookupImpl(doRemove, isLiteral,
                                               trie->branches[j], pattern, patternIdx + 1,
                                               results, maxResults,
                                               resultsIdx, &subtrieMatched);
                }
            }
        }

        if (trie->branches[j] != newBranch) {
            mustMakeNewTrie = true;
        }
        if (mustMakeNewTrie) {
            if (!subtrieMatched) {
                newBranches[newBranchesCount++] = newBranch;
            } else {
                // TODO: free newBranch
            }
        }

        allSubtriesMatched &= subtrieMatched;
    }

    if (mustMakeNewTrie) {
        const Trie* oldTrie = trie;
        Trie* newTrie = calloc(SIZEOF_TRIE(newBranchesCount), 1);
        memcpy(newTrie, oldTrie, SIZEOF_TRIE(0));
        memcpy(newTrie->branches, newBranches, newBranchesCount*sizeof(Trie*));
        trie = newTrie;
    }

    if (didMatchAllSubtries != NULL) {
        *didMatchAllSubtries = allSubtriesMatched;
    }
    return trie;
}

int trieLookup(const Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, false, trie, pattern, 0,
                   results, maxResults,
                   &resultCount, NULL);
    fprintf(stderr, "trieLookup: (%s) -> %d\n", clauseToString(pattern), resultCount);
    return resultCount;
}

int trieLookupLiteral(const Trie* trie, Clause* pattern,
                      uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, true, trie, pattern, 0,
                   results, maxResults,
                   &resultCount, NULL);
    return resultCount;
}

const Trie* trieRemove(const Trie* trie, Clause* pattern,
                       uint64_t* results, size_t maxResults,
                       int* resultCount) {
    return trieLookupImpl(true, false, trie, pattern, 0,
                          results, maxResults,
                          resultCount, NULL);
}
