#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>

#include <pthread.h>
#include <stdatomic.h>

#include "trie.h"
#include "db.h"

typedef struct ListOfEdgeTo {
    size_t capacityEdges;
    size_t nEdges; // This is an upper bound.
    uint64_t edges[];
} ListOfEdgeTo;
#define SIZEOF_LIST_OF_EDGE_TO(CAPACITY_EDGES) (sizeof(ListOfEdgeTo) + (CAPACITY_EDGES)*sizeof(uint64_t))

// Statement datatype:

typedef struct Statement {
    // How many acquired raw pointers to this statement exist? The
    // statement cannot be freed/invalidated as long as ptrCount >
    // 0. You must increment ptrCount before accessing any other field
    // in a Statement slot.
    _Atomic int ptrCount;

    // Immutable statement properties:

    // statementAcquire needs to increment the ptrCount _first_, then
    // check gen. gen cannot be mutated while ptrCount > 0.
    uint32_t gen;
    // Owned by the DB. clause cannot be mutated or invalidated while
    // ptrCount > 0.
    Clause* clause;

    // Mutable statement properties:

    // How many living Matches (or Holds or Asserts) are supporting
    // this statement? When parentCount hits 0, we deindex the
    // statement.
    _Atomic int parentCount;

    // ListOfEdgeTo MatchRef. Used for removal.
    ListOfEdgeTo* childMatches;
    pthread_mutex_t childMatchesMutex;

    // TODO: Cache of Jim-local clause objects?

} Statement;

// Match datatype:

typedef struct Match {
    _Atomic int ptrCount;

    // Immutable match properties:

    uint32_t gen;

    pthread_t workerThread;

    // Mutable match properties:

    // isCompleted is set to true once the Tcl evaluation that builds
    // the match is completed. As long as isCompleted is false,
    // workerThread is subject to termination signal (SIGUSR1) if the
    // match is removed.
    _Atomic bool isCompleted;

    _Atomic bool shouldFree;

    // TODO: Add match destructors.

    // ListOfEdgeTo StatementRef. Used for removal.
    ListOfEdgeTo* childStatements;
    pthread_mutex_t childStatementsMutex;
} Match;

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
    Statement statementPool[65536]; // slot 0 is reserved.
    _Atomic uint16_t statementPoolNextIdx;

    // Memory pool used to allocate matches.
    Match matchPool[65536]; // slot 0 is reserved.
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
void listOfEdgeToAdd(ListOfEdgeTo** listPtr, uint64_t to) {
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
    (*listPtr)->edges[(*listPtr)->nEdges++] = to;
}
void listOfEdgeToRemove(ListOfEdgeTo* list, uint64_t to) {
    assert(list != NULL);
    for (size_t i = 0; i < list->nEdges; i++) {
        if (list->edges[i] == to) {
            list->edges[i] = to;
        }
    }
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
        uint64_t edge = (*listPtr)->edges[i];
        // TODO: Also validate edge (is it a valid match / statement?)
        if (edge != 0) { list->edges[nEdges++] = edge; }
    }
    list->nEdges = nEdges;
    list->capacityEdges = (*listPtr)->capacityEdges;

    free(*listPtr);
    *listPtr = list;
}

////////////////////////////////////////////////////////////
// Removal:
////////////////////////////////////////////////////////////

static void reactToRemovedStatement(Db* db, Statement* stmt) {
    /* printf("reactToRemovedStatement: s%d:%d (%s)\n", stmt - &db->statementPool[0], stmt->gen, */
    /*        clauseToString(stmt->clause)); */
    pthread_mutex_lock(&stmt->childMatchesMutex);
    for (size_t i = 0; i < stmt->childMatches->nEdges; i++) {
        MatchRef childRef = { .val = stmt->childMatches->edges[i] };
        Match* child = matchAcquire(db, childRef);
        if (child != NULL) {
            // The removal of _any_ of a Match's statement parents
            // means the removal of that Match.
            matchRemoveSelf(db, child);
            matchRelease(db, child);
        }
    }
    pthread_mutex_unlock(&stmt->childMatchesMutex);
}
static void reactToRemovedMatch(Db* db, Match* match) {
    pthread_mutex_lock(&match->childStatementsMutex);
    for (size_t i = 0; i < match->childStatements->nEdges; i++) {
        StatementRef childRef = { .val = match->childStatements->edges[i] };
        Statement* child = statementAcquire(db, childRef);
        if (child != NULL) {
            statementRemoveParentAndMaybeRemoveSelf(db, child);
            statementRelease(db, child);
        }
    }
    pthread_mutex_unlock(&match->childStatementsMutex);
}

////////////////////////////////////////////////////////////
// Statement:
////////////////////////////////////////////////////////////

Statement* statementAcquire(Db* db, StatementRef ref) {
    if (ref.idx == 0) { return NULL; }

    Statement* s = &db->statementPool[ref.idx];
    // statementAcquire needs to increment the ptrCount _first_, then
    // check gen. (It's only guaranteed that no one can change gen or
    // otherwise invalidate the statement once ptrCount is
    // incremented.)
    s->ptrCount++;
    if (ref.gen < 0 || ref.gen != s->gen) {
        s->ptrCount--;
        return NULL;
    }
    return s;
}
void statementRelease(Db* db, Statement* stmt) {
    if (--stmt->ptrCount == 0 && stmt->parentCount == 0) {
        stmt->gen++; // Guard the rest of the freeing process.

        reactToRemovedStatement(db, stmt);

        /* printf("statementFree: %p (%.50s)\n", stmt, clauseToString(stmt->clause)); */
        /* Clause* stmtClause = statementClause(stmt); */
        /* for (int i = 0; i < stmtClause->nTerms; i++) { */
        /*     free(stmtClause->terms[i]); */
        /* } */
        /* free(stmtClause); */

        stmt->parentCount = 0;
        free(stmt->childMatches);
        stmt->childMatches = NULL;

        // How do we mark this statement slot as being fully free and
        // ready for reuse?
        stmt->clause = NULL;
    }
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
// becomes responsible for freeing it. Note: returns an acquired
// (ptrCount-incremented) statement pointer so it's safe to store in
// the index.
static StatementRef statementNew(Db* db, Clause* clause) {
    StatementRef ret;
    Statement* stmt = NULL;
    // Look for a free statement slot to use:
    while (1) {
        int32_t idx = db->statementPoolNextIdx++;
        if (idx == 0) { continue; }
        stmt = &db->statementPool[idx];

        ret = (StatementRef) { .gen = stmt->gen, .idx = idx };

        if (stmt->ptrCount == 0 && stmt->clause == NULL) {
            int expectedPtrCount = 0;
            if (atomic_compare_exchange_weak(&stmt->ptrCount, 
                                             &expectedPtrCount, 1)) {
                break;
            }
        }
    }
    // We should have exclusive access to stmt right now, because its
    // ptrCount is 1 but it's not pointed to by any ref or pointer
    // other than the one we have.

    stmt->clause = clause;

    stmt->parentCount = 1;
    stmt->childMatches = listOfEdgeToNew(8);
    pthread_mutex_init(&stmt->childMatchesMutex, NULL);

    // This won't free stmt until its parentCount is 0.
    stmt->ptrCount = 0;

    return ret;
}
Clause* statementClause(Statement* stmt) { return stmt->clause; }

void statementRemoveChildMatch(Statement* stmt, MatchRef to) {
    listOfEdgeToRemove(stmt->childMatches, to.val);
}

void statementAddChildMatch(Statement* stmt, MatchRef child) {
    listOfEdgeToAdd(&stmt->childMatches, child.val);
}
void statementAddParent(Statement* stmt) { stmt->parentCount++; }
void statementRemoveParentAndMaybeRemoveSelf(Db* db, Statement* stmt) {
    /* printf("statementRemoveParentAndMaybeRemoveSelf: s%d:%d\n", */
    /*        stmt - &db->statementPool[0], stmt->gen); */
    if (--stmt->parentCount == 0) {
        // Deindex the statement:
        uint64_t results[100];
        pthread_mutex_lock(&db->clauseToStatementIdMutex);
        int nResults = trieRemove(db->clauseToStatementId, stmt->clause,
                                  (uint64_t*) results, sizeof(results)/sizeof(results[0]));
        pthread_mutex_unlock(&db->clauseToStatementIdMutex);
        if (nResults != 1) {
            /* fprintf(stderr, "statementRemoveParentAndMaybeRemoveSelf: " */
            /*         "warning: trieRemove (%s) nResults != 1 (%d)\n", */
            /*         clauseToString(stmt->clause), */
            /*         nResults); */
        }

        reactToRemovedStatement(db, stmt);
    }
}

////////////////////////////////////////////////////////////
// Match:
////////////////////////////////////////////////////////////

Match* matchAcquire(Db* db, MatchRef ref) {
    if (ref.idx == 0) { return NULL; }

    Match* m = &db->matchPool[ref.idx];
    // matchAcquire needs to increment the ptrCount _first_, then
    // check gen. (It's only guaranteed that no one can change gen or
    // otherwise invalidate the match once ptrCount is incremented.)
    m->ptrCount++;
    if (ref.gen < 0 || ref.gen != m->gen) {
        m->ptrCount--; // TODO: what if this zeroes it?
        return NULL;
    }
    return m;
}
void matchRelease(Db* db, Match* match) {
    if (--match->ptrCount == 0 && match->shouldFree) {
        match->gen++; // Guard the rest of the freeing process.

        reactToRemovedMatch(db, match);

        free(match->childStatements);
        match->childStatements = NULL;
    }
}
MatchRef matchRef(Db* db, Match* match) {
    return (MatchRef) {
        .gen = match->gen,
        .idx = match - &db->matchPool[0]
    };
}

static MatchRef matchNew(Db* db) {
    MatchRef ret;
    Match* match = NULL;
    // Look for a free match slot to use:
    while (1) {
        int32_t idx = db->matchPoolNextIdx++;
        if (idx == 0) { continue; }
        match = &db->matchPool[idx];

        ret = (MatchRef) { .gen = match->gen, .idx = idx };

        if (match->ptrCount == 0 && match->childStatements == NULL) {
            int expectedPtrCount = 0;
            if (atomic_compare_exchange_weak(&match->ptrCount,
                                             &expectedPtrCount, 1)) {
                break;
            }
        }
    }

    // We should have exclusive access to match right now.

    match->childStatements = listOfEdgeToNew(8);
    pthread_mutex_init(&match->childStatementsMutex, NULL);
    match->isCompleted = false;
    match->shouldFree = false;

    // This won't free match until it's explicitly destroyed.
    match->ptrCount = 0;

    return ret;
}

void matchAddChildStatement(Match* match, StatementRef child) {
    listOfEdgeToAdd(&match->childStatements, child.val);
}
void matchCompleted(Match* match) {
    match->isCompleted = true;
}
void matchRemoveSelf(Db* db, Match* match) {
    /* printf("matchRemoveSelf: m%ld:%d\n", match - &db->matchPool[0], match->gen); */
    match->shouldFree = true;
    if (!match->isCompleted) {
        // Signal the match worker thread to terminate the match
        // execution.
        pthread_kill(match->workerThread, SIGUSR1);
    }
}

////////////////////////////////////////////////////////////
// Database:
////////////////////////////////////////////////////////////

Db* dbNew() {
    Db* ret = calloc(sizeof(Db), 1);

    ret->statementPool[0].gen = 0xFFFFFFFF;
    ret->statementPoolNextIdx = 1;

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

// Assumption: the db (statement addition) mutex is held by the
// caller. What happens if the parent match is removed at some point?
// How do we ensure that either this statement is retracted or it
// never appears?
StatementRef dbInsertOrReuseStatement(Db* db, Clause* clause, MatchRef parentMatchRef) {
    // Is this clause already present among the existing statements?
    StatementRef existingRefs[10];
    pthread_mutex_lock(&db->clauseToStatementIdMutex);
    int existingRefsCount = trieLookupLiteral(db->clauseToStatementId, clause,
                                              (uint64_t*) existingRefs,
                                              sizeof(existingRefs)/sizeof(existingRefs[0]));
    pthread_mutex_unlock(&db->clauseToStatementIdMutex);

    Match* parent = matchAcquire(db, parentMatchRef);
    if (!matchRefIsNull(parentMatchRef) && parent == NULL) {
        // Parent match has been invalidated -- abort!
        return STATEMENT_REF_NULL;
    }

    Statement* stmt;
    if (existingRefsCount == 1 && (stmt = statementAcquire(db, existingRefs[0]))) {
        // The clause already exists. We'll add the parents to the
        // existing statement instead of making a new statement.
        /* printf("Reuse: (%s)\n", clauseToString(clause)); */

        // FIXME: What if the parent has/will be destroyed?
        if (parent) {
            statementAddParent(stmt);
            matchAddChildStatement(parent, existingRefs[0]);
            matchRelease(db, parent);
        }
        statementRelease(db, stmt);
        return STATEMENT_REF_NULL;

    } else if (existingRefsCount == 0) {
        // The clause doesn't exist in a statement yet. Make the new
        // statement.

        StatementRef ref = statementNew(db, clause);
        pthread_mutex_lock(&db->clauseToStatementIdMutex);
        db->clauseToStatementId = trieAdd(db->clauseToStatementId, clause, ref.val);
        pthread_mutex_unlock(&db->clauseToStatementIdMutex);

        if (parent) {
            matchAddChildStatement(parent, ref);
            matchRelease(db, parent);
        }
        return ref;

    } else {
        // Invariant has been violated: somehow we have 2+ copies of
        // the same clause already in the db?
        fprintf(stderr, "Error: Clause duplicate\n"); exit(1);
    }
}

MatchRef dbInsertMatch(Db* db, size_t nParents, StatementRef parents[],
                       pthread_t workerThread) {
    MatchRef ref = matchNew(db);
    /* printf("dbInsertMatch: m%d:%d <- ", ref.idx, ref.gen); */
    Match* match = matchAcquire(db, ref);
    for (size_t i = 0; i < nParents; i++) {
        /* printf("s%d:%d ", parents[i].idx, parents[i].gen); */
        Statement* parent = statementAcquire(db, parents[i]);
        if (parent) {
            pthread_mutex_lock(&parent->childMatchesMutex);
            statementAddChildMatch(parent, ref);
            pthread_mutex_unlock(&parent->childMatchesMutex);

            statementRelease(db, parent);
        } else {
            // TODO: The parent is dead; we should abort/reverse this
            // whole thing.
            /* printf("dbInsertMatch: parent stmt was invalidated\n"); */
            matchRelease(db, match);
            return MATCH_REF_NULL;
        }
    }
    /* printf("\n"); */
    matchRelease(db, match);
    return ref;
}

void dbRetractStatements(Db* db, Clause* pattern) {
    StatementRef results[500];
    size_t maxResults = sizeof(results)/sizeof(results[0]);

    // TODO: Should we accept a StatementRef and enforce that is what
    // gets removed?
    pthread_mutex_lock(&db->clauseToStatementIdMutex);
    size_t nResults = trieLookup(db->clauseToStatementId, pattern,
                                 (uint64_t*) results, maxResults);
    pthread_mutex_unlock(&db->clauseToStatementIdMutex);

    if (nResults == maxResults) {
        // TODO: Try again with a larger maxResults?
        fprintf(stderr, "dbQuery: Hit max results\n"); exit(1);
    }

    for (size_t i = 0; i < nResults; i++) {
        Statement* stmt = statementAcquire(db, results[i]);
        statementRemoveParentAndMaybeRemoveSelf(db, stmt);
        statementRelease(db, stmt);
    }
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

        StatementRef newStmt = dbInsertOrReuseStatement(db, clause, MATCH_REF_NULL);
        hold->statement = newStmt;

        pthread_mutex_unlock(&hold->mutex);

        {
            uint64_t results[10];
            size_t maxResults = sizeof(results)/sizeof(results[0]);

            // TODO: Should we accept a StatementRef and enforce that
            // is what gets removed?
            Statement* oldStmtPtr = statementAcquire(db, oldStmt);
            if (oldStmtPtr) {
                // We deindex the old statement immediately, but we
                // leave it to the caller to actually remove it (and
                // therefore remove all its children).
                pthread_mutex_lock(&db->clauseToStatementIdMutex);
                trieRemove(db->clauseToStatementId,
                           statementClause(oldStmtPtr),
                           results, maxResults);
                pthread_mutex_unlock(&db->clauseToStatementIdMutex);

                statementRelease(db, oldStmtPtr);
            } else if (oldStmt.idx != 0) {
                fprintf(stderr, "Somehow old statement from Hold (%d:%d) was already removed?\n",
                        oldStmt.idx, oldStmt.gen);
            }

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

