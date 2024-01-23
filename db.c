#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>

#include "trie.h"
#include "db.h"

////////////////////////////////////////////////////////////
// EdgeTo and ListOfEdgeTo:
////////////////////////////////////////////////////////////

typedef enum { EDGE_EMPTY, EDGE_PARENT, EDGE_CHILD } EdgeType;
typedef struct {
    EdgeType type;
    void* to;
} EdgeTo;
typedef struct ListOfEdgeTo {
    size_t capacityEdges;
    size_t nEdges; // This is an estimate.
    EdgeTo edges[];
} ListOfEdgeTo;
#define SIZEOF_LIST_OF_EDGE_TO(CAPACITY_EDGES) (sizeof(ListOfEdgeTo) + (CAPACITY_EDGES)*sizeof(EdgeTo))
ListOfEdgeTo* listOfEdgeToNew(size_t capacityEdges) {
    ListOfEdgeTo* ret = calloc(SIZEOF_LIST_OF_EDGE_TO(capacityEdges), 1);
    ret->capacityEdges = capacityEdges;
    ret->nEdges = 0;
    return ret;
}
static void listOfEdgeToDefragment(ListOfEdgeTo** listPtr);
// Takes a double pointer to list because it may move the list to grow
// it (requiring replacement of the original pointer).
void listOfEdgeToAdd(ListOfEdgeTo** listPtr,
                     EdgeType type, void* to) {
    ListOfEdgeTo* list = *listPtr;
    if (list->nEdges == list->capacityEdges) {
        // We've run out of edge slots at the end of the
        // list. Try defragmenting the list.
        listOfEdgeToDefragment(&list);
        if (list->nEdges == list->capacityEdges) {
            // Still no slots? Grow the statement to
            // accommodate.
            list->capacityEdges = list->capacityEdges * 2;
            *listPtr = realloc(*listPtr, SIZEOF_LIST_OF_EDGE_TO(list->capacityEdges));
        }
    }

    assert(list->nEdges < list->capacityEdges);
    // There's a free slot at the end of the edgelist in
    // the statement. Use it.
    list->edges[list->nEdges++] = (EdgeTo) { .type = type, .to = to };
}
int listOfEdgeToRemove(ListOfEdgeTo* list,
                       EdgeType type, void* to) {
    assert(list != NULL);
    int parentEdges = 0;
    for (size_t i = 0; i < list->nEdges; i++) {
        EdgeTo* edge = &list->edges[i];
        if (edge->type == type && edge->to == to) {
            edge->type = EDGE_EMPTY;
            edge->to = NULL;
        }
        if (edge->type == EDGE_PARENT) { parentEdges++; }
    }
    return parentEdges;
}

// Given listPtr, moves all non-EMPTY edges to the front, then updates
// nEdges accordingly.
//
// Defragmentation is necessary to prevent continual growth of
// the statement edgelist if you keep adding and removing
// edges on the same statement.
static void listOfEdgeToDefragment(ListOfEdgeTo** listPtr) {
    // Copy all non-EMPTY edges into a new edgelist.
    ListOfEdgeTo* list = calloc(SIZEOF_LIST_OF_EDGE_TO((*listPtr)->capacityEdges), 1);
    size_t nEdges = 0;
    for (size_t i = 0; i < (*listPtr)->nEdges; i++) {
        EdgeTo* edge = &(*listPtr)->edges[i];
        if (edge->type != EDGE_EMPTY) { list->edges[nEdges++] = *edge; }
    }
    list->nEdges = nEdges;
    list->capacityEdges = (*listPtr)->capacityEdges;

    free(*listPtr);
    *listPtr = list;
}

////////////////////////////////////////////////////////////
// Statement:
////////////////////////////////////////////////////////////

typedef struct Match Match;

// Creates a new statement.
Statement* statementNew(Clause* clause,
                        size_t nParents, Match* parents[],
                        size_t nChildren, Match* children[]) {
    Statement* ret = malloc(sizeof(Statement));
    ret->clause = clause;
    ret->edges = listOfEdgeToNew((nParents + nChildren) * 2);
    for (size_t i = 0; i < nParents; i++) {
        listOfEdgeToAdd(&ret->edges, EDGE_PARENT, parents[i]);
    }
    for (size_t i = 0; i < nChildren; i++) {
        listOfEdgeToAdd(&ret->edges, EDGE_CHILD, children[i]);
    }
    return ret;
}
void statementAddChildMatch(Statement* stmt, Match* child) {
    listOfEdgeToAdd(&stmt->edges, EDGE_CHILD, child);
}
void statementAddParentMatch(Statement* stmt, Match* parent) {
    listOfEdgeToAdd(&stmt->edges, EDGE_PARENT, parent);
}

////////////////////////////////////////////////////////////
// Match:
////////////////////////////////////////////////////////////

struct Match {
    int32_t gen;
    bool alive;

    bool isFromCollect;
    Statement* collectId;

    // TODO: Add match destructors.

    // List of edges to parent & child Statements:
    ListOfEdgeTo* edges; // Allocated separately so it can be resized.
};

void matchAddChildStatement(Match* match, Statement* child) {
    listOfEdgeToAdd(&match->edges, EDGE_CHILD, child);
}
void matchAddParentStatement(Match* match, Statement* parent) {
    listOfEdgeToAdd(&match->edges, EDGE_PARENT, parent);
}

////////////////////////////////////////////////////////////
// Database:
////////////////////////////////////////////////////////////

typedef struct Db {
    // This is the primary trie (index) used for queries.
    Trie* clauseToStatementId;

    // TODO: Trie* clauseToReaction;
} Db;
// TODO: Implement locking.

Db* dbNew() {
    Db* ret = malloc(sizeof(Db));
    ret->clauseToStatementId = trieNew();
    return ret;
}
Trie* dbGetClauseToStatementId(Db* db) { return db->clauseToStatementId; }

// Query
ResultSet* dbQuery(Db* db, Clause* pattern) {
    uint64_t results[500];
    size_t maxResults = sizeof(results)/sizeof(results[0]);
    size_t nResults = trieLookup(db->clauseToStatementId, pattern,
                                    results, maxResults);
    if (nResults == maxResults) {
        // TODO: Try again with a larger maxResults?
        fprintf(stderr, "dbQuery: Hit max results\n"); exit(1);
    }

    ResultSet* ret = malloc(SIZEOF_RESULTSET(nResults));
    ret->nResults = nResults;
    for (size_t i = 0; i < nResults; i++) {
        ret->results[i] = (Statement*) results[i];
    }
    return ret;
}

void dbInsert(Db* db,
              Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement) {
    // Is this clause already present among the existing statements?
    uint64_t ids[10];
    int idslen = trieLookupLiteral(db->clauseToStatementId, clause,
                                   ids, sizeof(ids)/sizeof(ids[0]));
    Statement* id;
    if (idslen == 1) {
        id = (Statement *)&ids[0];
    } else if (idslen == 0) {
        id = NULL;
    } else {
        // Invariant has been violated: somehow we have 2+ copies of
        // the same clause already in the db?
        fprintf(stderr, "Error: Clause duplicate\n"); exit(1);
    }

    bool isNewStatement = id == NULL;
    if (isNewStatement) {
        id = statementNew(clause, nParents, parents, 0, NULL);
        db->clauseToStatementId = trieAdd(db->clauseToStatementId, clause, (uint64_t) id);

    } else {
        // The clause already exists. We'll add the parents to the
        // existing statement instead of making a new statement.
        for (size_t i = 0; i < nParents; i++) {
            statementAddParentMatch(id, parents[i]);
        }
    }

    for (size_t i = 0; i < nParents; i++) {
        if (parents[i] == NULL) { continue; } // ?
        matchAddChildStatement(parents[i], id);
    }

    if (outStatement) { *outStatement = id; }
    if (outIsNewStatement) { *outIsNewStatement = isNewStatement; }
}

// Remove
void dbRemove(Db* db, Clause* c) {
    
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

Statement* dbAssert(Db* db, Clause* clause) {
    Statement* ret; bool isNewStmt;
    dbInsert(db, clause, 0, NULL, &ret, &isNewStmt);
    assert(isNewStmt);
    return ret;
}


// FIXME: Test with multiple threads.
