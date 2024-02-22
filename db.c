#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>

#include <pthread.h>

#include "trie.h"
#include "db.h"

// Ref datatypes:

typedef struct EdgeTo {
    EdgeType type;
    uint64_t to;
} EdgeTo;
typedef struct ListOfEdgeTo {
    size_t capacityEdges;
    size_t nEdges; // This is an upper bound.
    EdgeTo edges[];
} ListOfEdgeTo;
#define SIZEOF_LIST_OF_EDGE_TO(CAPACITY_EDGES) (sizeof(ListOfEdgeTo) + (CAPACITY_EDGES)*sizeof(EdgeTo))

// Statement datatype:

typedef struct Statement {
    uint32_t gen;
    pthread_mutex_t mutex;

    Clause* clause; // Owned by the DB.

    // List of edges to parent & child Matches:
    ListOfEdgeTo* edges; // Allocated separately so it can be resized.

    // TODO: Cache of Jim-local clause objects?

    // TODO: Lock? Refcount?
    // Retracter will ???
} Statement;

// Match datatype:

struct Match {
    uint32_t gen;
    pthread_mutex_t mutex;

    /* bool isFromCollect; */
    /* Statement* collectId; */

    // TODO: Add match destructors.

    // List of edges to parent & child Statements:
    ListOfEdgeTo* edges; // Allocated separately so it can be resized.
};

// Database datatypes:

typedef struct Hold {
    pthread_mutex_t mutex;

    // If key == NULL, then this Hold is an empty slot that can be
    // used for a new hold key.
    const char* key; // Owned by the DB.
    int64_t version;

    StatementRef statement;
} Hold;

typedef struct Db {
    // Memory pool used to allocate statements.
    Statement statementPool[32768]; // slot 0 is reserved.
    _Atomic uint16_t statementPoolNextIdx;

    // Memory pool used to allocate matches.
    Match matchPool[32768]; // slot 0 is reserved.
    _Atomic uint16_t matchPoolNextIdx;

    // Primary trie (index) used for queries.
    Trie* clauseToStatementId;
    pthread_mutex_t clauseToStatementIdMutex;

    // One for each Hold key, which always stores the highest-version
    // held statement for that key. We keep this map so that we can
    // overwrite out-of-date Holds for a key as soon as a newer one
    // comes in, without having to actually emit and react to the
    // statement.
    Hold holds[256];
} Db;

////////////////////////////////////////////////////////////
// EdgeTo and ListOfEdgeTo:
////////////////////////////////////////////////////////////

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
                     EdgeType type, uint64_t to) {
    if ((*listPtr)->nEdges == (*listPtr)->capacityEdges) {
        // We've run out of edge slots at the end of the
        // list. Try defragmenting the list.
        listOfEdgeToDefragment(listPtr);
        if ((*listPtr)->nEdges == (*listPtr)->capacityEdges) {
            // Still no slots? Grow the statement to
            // accommodate.
            (*listPtr)->capacityEdges = (*listPtr)->capacityEdges * 2;
            *listPtr = realloc(*listPtr, SIZEOF_LIST_OF_EDGE_TO((*listPtr)->capacityEdges));
        }
    }

    assert((*listPtr)->nEdges < (*listPtr)->capacityEdges);
    // There's a free slot at the end of the edgelist in
    // the statement. Use it.
    (*listPtr)->edges[(*listPtr)->nEdges++] = (EdgeTo) { .type = type, .to = to };
}
int listOfEdgeToRemove(ListOfEdgeTo* list,
                       EdgeType type, uint64_t to) {
    assert(list != NULL);
    int parentEdges = 0;
    for (size_t i = 0; i < list->nEdges; i++) {
        EdgeTo* edge = &list->edges[i];
        if (edge->type == type && edge->to == to) {
            edge->type = EDGE_EMPTY;
            edge->to = 0;
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

Statement* statementAcquire(Db* db, StatementRef stmt) {
    Statement* s = &db->statementPool[stmt.idx];
    pthread_mutex_lock(&s->mutex);
    if (stmt.gen >= 0 && stmt.gen == s->gen) { return s; }

    pthread_mutex_unlock(&s->mutex);
    return NULL;
}
void statementRelease(Statement* s) {
    pthread_mutex_unlock(&s->mutex);
}
StatementRef statementRef(Db* db, Statement* stmt) {
    return (StatementRef) {
        .gen = stmt->gen,
        .idx = stmt - &db->statementPool[0]
    };
}

// Creates a new statement. Internal helper for the DB, not callable
// from the outside (they need to insert into the DB as a complete
// operation). Note: clause ownership transfers to the DB, which then
// becomes responsible for freeing it.
static StatementRef statementNew(Db* db,
                                 Clause* clause,
                                 size_t nParents, MatchRef parents[],
                                 size_t nChildren, MatchRef children[]) {
    StatementRef ret;
    Statement* stmt = NULL;
    do {
        if (stmt != NULL) { pthread_mutex_unlock(&stmt->mutex); }

        int32_t idx = db->statementPoolNextIdx++;
        stmt = &db->statementPool[idx];
        pthread_mutex_lock(&stmt->mutex);

        ret = (StatementRef) { .gen = stmt->gen, .idx = idx };
    } while (stmt->clause != NULL || ret.idx == 0);

    stmt->clause = clause;
    stmt->edges = listOfEdgeToNew((nParents + nChildren) * 2 < 8 ?
                                 8 : (nParents + nChildren) * 2 < 8);
    for (size_t i = 0; i < nParents; i++) {
        listOfEdgeToAdd(&stmt->edges, EDGE_PARENT, parents[i].val);
    }
    for (size_t i = 0; i < nChildren; i++) {
        listOfEdgeToAdd(&stmt->edges, EDGE_CHILD, children[i].val);
    }
    pthread_mutex_unlock(&stmt->mutex);
    return ret;
}
Clause* statementClause(Statement* stmt) { return stmt->clause; }

StatementEdgeIterator statementEdgesBegin(Statement* stmt) {
    return (StatementEdgeIterator) { .stmt = stmt, .idx = 0 };
}
bool statementEdgesIsEnd(StatementEdgeIterator it) {
    return it.idx == it.stmt->edges->nEdges;
}
StatementEdgeIterator statementEdgesNext(StatementEdgeIterator it) {
    return (StatementEdgeIterator) { .stmt = it.stmt, .idx = it.idx + 1 };
}
EdgeType statementEdgeType(StatementEdgeIterator it) {
    return it.stmt->edges->edges[it.idx].type;
}
MatchRef statementEdgeMatch(StatementEdgeIterator it) {
    return *(MatchRef*) &it.stmt->edges->edges[it.idx].to;
}

int statementRemoveEdgeToMatch(Statement* stmt, EdgeType type, MatchRef to) {
    return listOfEdgeToRemove(stmt->edges, type, to.val);
}

void statementFree(Statement* stmt) {
    printf("statementFree: %p (%.50s)\n", stmt, clauseToString(stmt->clause));
    /* Clause* stmtClause = statementClause(stmt); */
    /* for (int i = 0; i < stmtClause->nTerms; i++) { */
    /*     free(stmtClause->terms[i]); */
    /* } */
    /* free(stmtClause); */
    free(stmt->edges);
    stmt->clause = NULL;
    stmt->edges = NULL;
    stmt->gen++;
}

void statementAddChildMatch(Statement* stmt, MatchRef child) {
    listOfEdgeToAdd(&stmt->edges, EDGE_CHILD, child.val);
}
void statementAddParentMatch(Statement* stmt, MatchRef parent) {
    listOfEdgeToAdd(&stmt->edges, EDGE_PARENT, parent.val);
}

////////////////////////////////////////////////////////////
// Match:
////////////////////////////////////////////////////////////

Match* matchAcquire(Db* db, MatchRef match) {
    Match* m = &db->matchPool[match.idx];
    pthread_mutex_lock(&m->mutex);
    if (match.gen == m->gen) { return m; }

    pthread_mutex_unlock(&m->mutex);
    return NULL;
}
void matchRelease(Match* m) {
    pthread_mutex_unlock(&m->mutex);
}
MatchRef matchRef(Db* db, Match* match) {
    return (MatchRef) {
        .gen = match->gen,
        .idx = match - &db->matchPool[0]
    };
}

static MatchRef matchNew(Db* db,
                         size_t nParents, StatementRef parents[]) {
    MatchRef ret;
    Match* match = NULL;
    do {
        if (match != NULL) { pthread_mutex_unlock(&match->mutex); }

        int32_t idx = db->matchPoolNextIdx++;
        match = &db->matchPool[idx];
        pthread_mutex_lock(&match->mutex);

        ret = (MatchRef) { .gen = match->gen, .idx = idx };
    } while (match->edges != NULL || ret.idx == 0);

    match->edges = listOfEdgeToNew(nParents * 2);
    for (size_t i = 0; i < nParents; i++) {
        listOfEdgeToAdd(&match->edges, EDGE_PARENT,
                        parents[i].val);
    }
    pthread_mutex_unlock(&match->mutex);
    return ret;
}

void matchFree(Match* match) {
    free(match->edges);
    match->edges = NULL;
    match->gen = (match->gen + 1) % INT32_MAX;
}

MatchEdgeIterator matchEdgesBegin(Match* match) {
    return (MatchEdgeIterator) { .match = match, .idx = 0 };
}
bool matchEdgesIsEnd(MatchEdgeIterator it) {
    return it.idx == it.match->edges->nEdges;
}
MatchEdgeIterator matchEdgesNext(MatchEdgeIterator it) {
    return (MatchEdgeIterator) { .match = it.match, .idx = it.idx + 1 };
}
EdgeType matchEdgeType(MatchEdgeIterator it) {
    return it.match->edges->edges[it.idx].type;
}
StatementRef matchEdgeStatement(MatchEdgeIterator it) {
    return (StatementRef) { .val = it.match->edges->edges[it.idx].to };
}

void matchAddChildStatement(Match* match, StatementRef child) {
    listOfEdgeToAdd(&match->edges, EDGE_CHILD, child.val);
}
void matchAddParentStatement(Match* match, StatementRef parent) {
    listOfEdgeToAdd(&match->edges, EDGE_PARENT, parent.val);
}

////////////////////////////////////////////////////////////
// Database:
////////////////////////////////////////////////////////////

Db* dbNew() {
    Db* ret = calloc(sizeof(Db), 1);

    for (int i = 0; i < sizeof(ret->statementPool)/sizeof(ret->statementPool[0]); i++) {
        pthread_mutex_init(&ret->statementPool[i].mutex, NULL);
    }
    ret->statementPool[0].gen = 0xFFFFFFFF;
    ret->statementPoolNextIdx = 1;

    for (int i = 0; i < sizeof(ret->matchPool)/sizeof(ret->matchPool[0]); i++) {
        pthread_mutex_init(&ret->matchPool[i].mutex, NULL);
    }
    ret->matchPool[0].gen = 0xFFFFFFFF;
    ret->matchPoolNextIdx = 1;

    ret->clauseToStatementId = trieNew();
    pthread_mutex_init(&ret->clauseToStatementIdMutex, NULL);

    for (int i = 0; i < sizeof(ret->holds)/sizeof(ret->holds[0]); i++) {
        pthread_mutex_init(&ret->holds[i].mutex, NULL);
    }

    return ret;
}
Trie* dbGetClauseToStatementId(Db* db) { return db->clauseToStatementId; }

// Query
ResultSet* dbQuery(Db* db, Clause* pattern) {
    StatementRef results[500];
    size_t maxResults = sizeof(results)/sizeof(results[0]);

    pthread_mutex_lock(&db->clauseToStatementIdMutex);
    size_t nResults = trieLookup(db->clauseToStatementId, pattern,
                                 (uint64_t*) results, maxResults);
    pthread_mutex_unlock(&db->clauseToStatementIdMutex);

    if (nResults == maxResults) {
        // TODO: Try again with a larger maxResults?
        fprintf(stderr, "dbQuery: Hit max results\n"); exit(1);
    }

    ResultSet* ret = malloc(SIZEOF_RESULTSET(nResults));
    ret->nResults = nResults;
    for (size_t i = 0; i < nResults; i++) {
        ret->results[i] = results[i];
    }
    return ret;
}

StatementRef dbInsertStatement(Db* db, Clause* clause,
                               size_t nParents, MatchRef parents[]) {
    // Is this clause already present among the existing statements?
    uint64_t ids[10];

    // What if I run 2 insert statements in parallel that both have
    // the same clause? Desired outcome: get one statement in DB with
    // merged set of parents.

    pthread_mutex_lock(&db->clauseToStatementIdMutex);
    int idslen = trieLookupLiteral(db->clauseToStatementId, clause,
                                   (uint64_t*) ids, sizeof(ids)/sizeof(ids[0]));

    StatementRef ref = {0};
    Statement* stmt;
    bool needNewStatement;
    if (idslen == 1) {
        // The clause already exists. We'll add the parents to the
        // existing statement instead of making a new statement.
        printf("Reuse: (%s)\n", clauseToString(clause));

        ref = (StatementRef) { .val = ids[0] };
        stmt = statementAcquire(db, ref);

        pthread_mutex_unlock(&db->clauseToStatementIdMutex);

        for (size_t i = 0; i < nParents; i++) {
            statementAddParentMatch(stmt, parents[i]);
        }
        statementRelease(stmt);

        for (size_t i = 0; i < nParents; i++) {
            Match* parent = matchAcquire(db, parents[i]);
            if (parent) {
                matchAddChildStatement(parent, ref);
                matchRelease(parent);
            } else {
                // TODO: Acquire statement, check if statement has any
                // other valid parents besides this one? If not, then
                // destroy the statement.
                printf("dbInsertStatement: parent match was invalidated\n");
            }
        }
        return STATEMENT_REF_NULL;

    } else if (idslen == 0) {
        // The clause doesn't exist in a statement yet. Make the new
        // statement.

        ref = statementNew(db, clause, nParents, parents, 0, NULL);
        db->clauseToStatementId = trieAdd(db->clauseToStatementId, clause, ref.val);

        // Notice how we do the lookup and add in one section while
        // holding the trie mutex, so that any parallel threads won't
        // have a chance to double-add the same clause at the same
        // time.
        pthread_mutex_unlock(&db->clauseToStatementIdMutex);

        for (size_t i = 0; i < nParents; i++) {
            Match* parent = matchAcquire(db, parents[i]);
            if (parent) {
                matchAddChildStatement(parent, ref);
                matchRelease(parent);
            } else {
                // TODO: Acquire statement, check if statement has any
                // other valid parents besides this one? If not, then
                // destroy the statement.
                printf("dbInsertStatement: parent match was invalidated\n");
            }
        }
        return ref;

    } else {
        // Invariant has been violated: somehow we have 2+ copies of
        // the same clause already in the db?
        fprintf(stderr, "Error: Clause duplicate\n"); exit(1);
    }
}

MatchRef dbInsertMatch(Db* db,
                       size_t nParents, StatementRef parents[]) {
    MatchRef match = matchNew(db, nParents, parents);
    for (size_t i = 0; i < nParents; i++) {
        Statement* parent = statementAcquire(db, parents[i]);
        if (parent) {
            statementAddChildMatch(parent, match);
            statementRelease(parent);
        } else {
            // TODO: The parent is dead; we should abort/reverse this
            // whole thing.
            printf("dbInsertMatch: parent stmt was invalidated\n");
        }
    }
    return match;
}

ResultSet* dbQueryAndDeindexStatements(Db* db, Clause* pattern) {
    uint64_t results[500];
    size_t maxResults = sizeof(results)/sizeof(results[0]);

    pthread_mutex_lock(&db->clauseToStatementIdMutex);
    // TODO: Should we accept a StatementRef and enforce that is what
    // gets removed?
    size_t nResults = trieRemove(db->clauseToStatementId, pattern,
                                 results, maxResults);
    pthread_mutex_unlock(&db->clauseToStatementIdMutex);

    if (nResults == maxResults) {
        // TODO: Try again with a larger maxResults?
        fprintf(stderr, "dbQuery: Hit max results\n"); exit(1);
    }

    ResultSet* ret = malloc(SIZEOF_RESULTSET(nResults));
    ret->nResults = nResults;
    for (size_t i = 0; i < nResults; i++) {
        ret->results[i] = (StatementRef) { .val = results[i] };
    }
    return ret;
}

StatementRef dbHoldStatement(Db* db,
                             const char* key, int64_t version,
                             Clause* clause,
                             StatementRef* outOldStatement) {
    *outOldStatement = STATEMENT_REF_NULL;

    Hold* hold = NULL;
    for (int i = 0; i < sizeof(db->holds)/sizeof(db->holds[0]); i++) {
        pthread_mutex_lock(&db->holds[i].mutex);
        if (db->holds[i].key != NULL && strcmp(db->holds[i].key, key) == 0) {
            hold = &db->holds[i];
            break;
        } else {
            pthread_mutex_unlock(&db->holds[i].mutex);
        }
    }
    if (hold == NULL) {
        for (int i = 0; i < sizeof(db->holds)/sizeof(db->holds[0]); i++) {
            pthread_mutex_lock(&db->holds[i].mutex);
            if (db->holds[i].key == NULL) {
                hold = &db->holds[i];
                hold->key = key;
                break;
            } else {
                pthread_mutex_unlock(&db->holds[i].mutex);
            }
        }
    }
    // Note that we should be still holding the mutex for `hold` at
    // this point.

    if (hold == NULL) {
        fprintf(stderr, "dbHoldStatement: Ran out of hold slots\n");
        exit(1);
    }

    if (version < 0) {
        version = hold->version + 1;
    }
    if (version > hold->version) {
        StatementRef oldStmt = hold->statement;

        hold->version = version;

        StatementRef newStmt = dbInsertStatement(db, clause, 0, NULL);
        hold->statement = newStmt;

        pthread_mutex_unlock(&hold->mutex);

        if (statementRefIsNonNull(oldStmt)) {
            uint64_t results[10];
            size_t maxResults = sizeof(results)/sizeof(results[0]);

            pthread_mutex_lock(&db->clauseToStatementIdMutex);
            // TODO: Should we accept a StatementRef and enforce that
            // is what gets removed?
            trieRemove(db->clauseToStatementId,
                       statementClause(statementAcquire(db, oldStmt)),
                       results, maxResults);
            pthread_mutex_unlock(&db->clauseToStatementIdMutex);
            /* assert(nRemoved == 1); */
            /* assert(results[0] == oldStmt.val); */

            if (outOldStatement) { *outOldStatement = oldStmt; }
        }

        return newStmt;
    } else {
        // The new version is older than the version already in the
        // hold, so we just shouldn't do anything / we shouldn't
        // install the new statement.
        pthread_mutex_unlock(&hold->mutex);
        return STATEMENT_REF_NULL;
    }
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
    c->nTerms = i;
    return c;
}
