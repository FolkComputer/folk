#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "trie.h"

struct Term {
    int32_t len;
    char buf[];
};
#define SIZEOF_TERM(LEN) (sizeof(Term) + (LEN)*sizeof(uint8_t))
Term* termNew(const char* s, int len) {
    if (len == -1) { len = strlen(s); }
    Term* t = malloc(SIZEOF_TERM(len));
    t->len = len;
    memcpy(t->buf, s, len);
    return t;
}
Term* termDup(void *(*alloc)(size_t), const Term* t) {
    Term* t1 = alloc(SIZEOF_TERM(t->len));
    t1->len = t->len;
    memcpy(t1->buf, t->buf, t1->len);
    return t1;
}
int termLen(const Term* t) {
    return t->len;
}
const char* termPtr(const Term* t) {
    return t->buf;
}
bool termEq(const Term* t1, const Term* t2) {
    if (t1->len != t2->len) return false;
    return memcmp(t1->buf, t2->buf, t1->len) == 0;
}
bool termEqString(const Term* t, const char* s) {
    int sLen = strlen(s);
    if (sLen != t->len) { return false; }
    return memcmp(t->buf, s, sLen) == 0;
}

#define SIZEOF_CLAUSE(NTERMS) (sizeof(Clause) + (NTERMS)*sizeof(char*))
Clause* clauseNew(int32_t nTerms) {
    Clause* c = calloc(SIZEOF_CLAUSE(nTerms), 1);
    c->nTerms = nTerms;
    return c;
}
Clause* clauseDup(Clause* c) {
    Clause* ret = malloc(SIZEOF_CLAUSE(c->nTerms));
    ret->nTerms = c->nTerms;
    for (int i = 0; i < c->nTerms; i++) {
        ret->terms[i] = termDup(malloc, c->terms[i]);
    }
    return ret;
}
void clauseFree(Clause* c) {
    for (int i = 0; i < c->nTerms; i++) {
        free(c->terms[i]);
    }
    free(c);
}
void clauseFreeBorrowed(Clause* c) {
    free(c);
}

char* clauseToString(Clause* c) {
    if (c == NULL) {
        return strdup("<null clause>");
    } else if (c->nTerms <= 0 || c->nTerms > 100) {
        return strdup("<invalid clause>");
    }

    int totalLength = 0;
    for (int i = 0; i < c->nTerms; i++) {
        // +1 for the space between terms
        totalLength += termLen(c->terms[i]) + 1;
    }
    char* ret; char* s; ret = s = malloc(totalLength + 1);
    for (int i = 0; i < c->nTerms; i++) {
        memcpy(s, termPtr(c->terms[i]), termLen(c->terms[i]));
        s += termLen(c->terms[i]);
        *s = ' ';
        s++;
    }
    *s = '\0';
    return ret;
}
bool clauseIsEqual(Clause* a, Clause* b) {
    if (a->nTerms != b->nTerms) { return false; }
    for (int32_t i = 0; i < a->nTerms; i++) {
        if (!termEq(a->terms[i], b->terms[i])) {
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

// This will return the original trie if the clause is already present
// in it.
static const Trie* trieAddImpl(const Trie* trie,
                               void *(*alloc)(size_t), void (*retire)(void*),
                               int32_t nTerms, Term* terms[], uint64_t value) {
    if (nTerms == 0) {
        if (trie->hasValue) {
            // This clause is already present.
            return trie;
        }
        Trie* newTrie = alloc(SIZEOF_TRIE(trie->branchesCount));
        memcpy(newTrie, trie, SIZEOF_TRIE(trie->branchesCount));
        newTrie->value = value;
        newTrie->hasValue = true;
        retire((void *)trie);
        return newTrie;
    }
    Term* term = terms[0];

    // Is there an existing branch that already matches the first
    // term?
    int j;
    for (j = 0; j < trie->branchesCount; j++) {
        const Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (termEq(branch->key, term)) {
            break;
        }
    }

    const Trie* addToBranch;
    Trie* newBranch = NULL;
    if (j == trie->branchesCount) {
        // Need to add a new branch.
        newBranch = alloc(SIZEOF_TRIE(0));
        newBranch->key = termDup(alloc, term);
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
    retire((void *)trie);
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


bool trieScanVariable(Term* term, char* outVarName, int sizeOutVarName) {
    if (term->buf[0] != '/') { return false; }
    if (term->buf[term->len - 1] != '/') { return false; }

    int varLen = term->len - 2;
    if (varLen < 1 || varLen > sizeOutVarName) { return false; }

    for (int i = 0; i < varLen; i++) {
        if (term->buf[1 + i] == ' ') {
            return false;
        }
        outVarName[i] = term->buf[1 + i];
    }
    outVarName[varLen] = '\0';
    return true;
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

    Term* term = pattern->terms[patternIdx];
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
                if (termEq(trie->branches[j]->key, term)) {
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

    Term* term = pattern->terms[patternIdx];
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
                if (termEq(trie->branches[j]->key, term)) {
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
