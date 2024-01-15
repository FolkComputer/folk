#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>

#include "trie.h"

// TODO: Interprocess heap

// What is the db?
// Can we make a trie and have that be authoritative?
// Need to store data in each statement too

typedef struct Result {
    char* blup;
} Result;
typedef struct ResultSet {
    int32_t nresults;
    Result* results[];
} ResultSet;

Trie* clauseToStatementId;

// Query
ResultSet* query(Clause* c) {
    return NULL;
}

// Add
void add(Clause* c) {
    // add to db
    trieAdd(clauseToStatementId, c, 1);
}

// Remove
void remove(Clause* c) {
    
}

// Test:
Clause* clause(char* first, ...) {
    Clause* c = calloc(sizeof(Clause) + sizeof(char*)*100, 1);
    va_list argp;
    va_start(argp, first);
    c->terms[0] = first;
    int i = 1;
    for (;;) {
        if (i >= 100) abort();
        c->terms[i] = va_arg(argp, char*);
        if (c->terms[i] == 0) break;
        i++;
    }
    va_end(argp);
    c->nterms = i;
    return c;
}
int main() {
    clauseToStatementId = trieCreate();
    add(clause("This", "is", "a", "thing", 0));
    query(clause("This", "is", "a", "thing", 0));
}

// FIXME: Implement query.
// FIXME: Implement Graphviz output.
// FIXME: Test with multiple threads.
