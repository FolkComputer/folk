// Plan: we'll use locks for the trie at first, then switch to some
// sort of RCU scheme.

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "trie.h"

Trie* trieNew() {
    size_t size = sizeof(Trie) + 10*sizeof(Trie*);
    Trie* ret = (Trie*) calloc(size, 1);
    *ret = (Trie) {
        .key = NULL,
        .hasValue = false,
        .value = 0,
        .nbranches = 10
    };
    return ret;
}

static Trie* trieAddImpl(Trie* trie, int32_t nTerms, const char* terms[], uint64_t value) {
    if (nTerms == 0) {
        trie->value = value;
        trie->hasValue = true;
        return trie;
    }
    const char* term = terms[0];

    Trie* match = NULL;

    int j;
    for (j = 0; j < trie->nbranches; j++) {
        Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (branch->key == term || strcmp(branch->key, term) == 0) {
            match = branch;
            break;
        }
    }

    if (match == NULL) { // add new branch
        if (j == trie->nbranches) {
            // We're out of room; need to grow trie.
            Trie* old = trie;
            trie = malloc(SIZEOF_TRIE(2*trie->nbranches));
            memcpy(trie, old, SIZEOF_TRIE(old->nbranches));

            trie->nbranches *= 2;
            memset(trie->branches[j], 0, (trie->nbranches/2)*sizeof(Trie*));
            // TODO: Free old.
        }

        Trie* branch = calloc(SIZEOF_TRIE(10), 1);
        branch->key = term;
        branch->value = 0;
        branch->hasValue = false;
        branch->nbranches = 10;

        // TODO: Need to change trie if branch changes.
        trie->branches[j] = branch;
        match = trie->branches[j];
    }

    trieAddImpl(match, nTerms - 1, terms + 1, value);
    return trie;
}

Trie* trieAdd(Trie* trie, Clause* c, uint64_t value) {
    return trieAddImpl(trie, c->nTerms, c->terms, value);
}


bool scanVariable(const char* term, char* outVarName, size_t sizeOutVarName) {
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

static void trieLookupAll(Trie* trie,
                          uint64_t* results, size_t maxResults, int* resultsIdx) {
    if (trie->hasValue) {
        if (*resultsIdx < maxResults) {
            results[(*resultsIdx)++] = trie->value;
        }
    }
    for (int j = 0; j < trie->nbranches; j++) {
        if (trie->branches[j] == NULL) { break; }
        trieLookupAll(trie->branches[j],
                      results, maxResults, resultsIdx);
    }
}
static void trieLookupImpl(bool isLiteral, Trie* trie, Clause* pattern, int patternIdx,
                           uint64_t* results, size_t maxResults, int* resultsIdx) {
    int wordc = pattern->nTerms - patternIdx;
    if (wordc == 0) {
        if (trie->hasValue) {
            if (*resultsIdx < maxResults) {
                results[(*resultsIdx)++] = trie->value;
            }
        }
        return;
    }

    const char* term = pattern->terms[patternIdx];
    enum { TERM_TYPE_LITERAL, TERM_TYPE_VARIABLE, TERM_TYPE_REST_VARIABLE } termType;
    char termVarName[100];
    if (!isLiteral && scanVariable(term, termVarName, 100)) {
        if (termVarName[0] == '.' && termVarName[1] == '.' && termVarName[2] == '.') {
            termType = TERM_TYPE_REST_VARIABLE;
        } else { termType = TERM_TYPE_VARIABLE; }
    } else { termType = TERM_TYPE_LITERAL; }

    for (int j = 0; j < trie->nbranches; j++) {
        if (trie->branches[j] == NULL) { break; }

        // Easy cases:
        if (trie->branches[j]->key == term || // Is there an exact pointer match?
            termType == TERM_TYPE_VARIABLE) { // Is the current lookup term a variable?
            trieLookupImpl(isLiteral, trie->branches[j], pattern, patternIdx + 1,
                           results, maxResults, resultsIdx);

        } else if (termType == TERM_TYPE_REST_VARIABLE) {
            trieLookupAll(trie->branches[j],
                          results, maxResults, resultsIdx);

        } else {
            char keyVarName[100];
            // Is the trie node (we're currently walking) a variable?
            if (!isLiteral && scanVariable(trie->branches[j]->key, keyVarName, 100)) {
                // Is the trie node a rest variable?
                if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                    /* lookupAll(results, resultsIdx, maxresults, trie->branches[j]); */

                } else { // Or is the trie node a normal variable?
                    trieLookupImpl(isLiteral, trie->branches[j], pattern, patternIdx + 1,
                                   results, maxResults, resultsIdx);
                }
            } else {
                const char *keyString = trie->branches[j]->key;
                const char *termString = term;
                if (strcmp(keyString, termString) == 0) {
                    trieLookupImpl(isLiteral, trie->branches[j], pattern, patternIdx + 1,
                                   results, maxResults, resultsIdx);
                }
            }
        }
    }
}

int trieLookup(Trie* trie, Clause* pattern,
               uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(false, trie, pattern, 0,
                   results, maxResults, &resultCount);
    return resultCount;
}

int trieLookupLiteral(Trie* trie, Clause* pattern,
                      uint64_t* results, size_t maxResults) {
    int resultCount = 0;
    trieLookupImpl(true, trie, pattern, 0,
                   results, maxResults, &resultCount);
    return resultCount;
}

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
static bool isNonCapturing(const char* varName) {
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
Environment* clauseUnify(Clause* a, Clause* b) {
    Environment* env = malloc(sizeof(Environment) + sizeof(EnvironmentBinding)*a->nTerms);

    for (int i = 0; i < a->nTerms; i++) {
        char aVarName[100] = {0}; char bVarName[100] = {0};
        if (scanVariable(a->terms[i], aVarName, sizeof(aVarName))) {
            if (!isNonCapturing(aVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = b->terms[i];
            }
        } else if (scanVariable(b->terms[i], bVarName, sizeof(bVarName))) {
            if (!isNonCapturing(bVarName)) {
                EnvironmentBinding* binding = &env->bindings[env->nBindings++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = a->terms[i];
            }
        } else if (!(a->terms[i] == b->terms[i] ||
                     strcmp(a->terms[i], b->terms[i]) == 0)) {
            free(env);
            fprintf(stderr, "clauseUnify: Unification of (%s) (%s) failed\n",
                    clauseToString(a), clauseToString(b));
            return NULL;
        }
    }
    return env;
}
