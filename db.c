#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
#include <string.h>

#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>

#include "trie.h"
#include "db.h"

typedef struct ListOfEdgeTo {
    size_t capacityEdges;
    size_t nEdges; // This is an upper bound.
    uint64_t edges[];
} ListOfEdgeTo;
#define SIZEOF_LIST_OF_EDGE_TO(CAPACITY_EDGES) (sizeof(ListOfEdgeTo) + (CAPACITY_EDGES)*sizeof(uint64_t))
typedef bool (*ListEdgeCheckerFn)(void* arg, uint64_t edge);


typedef struct GenRc {
    // How many acquired raw pointers to this object exist? The object
    // cannot be freed/invalidated as long as rc > 0. You must
    // increment rc before accessing any other field in the object.
    int16_t rc;

    int gen: 15;
    bool alive: 1;
} GenRc;

bool genRcAcquire(_Atomic GenRc* genRcPtr, int32_t gen) {
    GenRc oldGenRc;
    GenRc newGenRc;
    do {
        oldGenRc = *genRcPtr;
        if (oldGenRc.gen < 0 || oldGenRc.gen != gen) {
            return false;
        }

        newGenRc = oldGenRc;
        newGenRc.rc++;

    } while (!atomic_compare_exchange_weak(genRcPtr, &oldGenRc, newGenRc));

    return true;
}
bool genRcRelease(_Atomic GenRc* genRcPtr) {
    GenRc oldGenRc;
    GenRc newGenRc;
    bool callerShouldFree = false;
    do {
        oldGenRc = *genRcPtr;
        newGenRc = oldGenRc;

        --newGenRc.rc;
        callerShouldFree = !oldGenRc.alive && (newGenRc.rc == 0);
        if (callerShouldFree) {
            newGenRc.gen++;
        }

    } while (!atomic_compare_exchange_weak(genRcPtr, &oldGenRc, newGenRc));
    return callerShouldFree;
}
void genRcMarkAsDead(_Atomic GenRc* genRcPtr) {
    // ASSUMES that rc > 0 (because the caller must have acquired the
    // rc before calling us), which means gen cannot change. We do the
    // loop here in case the rc changes.
    GenRc oldGenRc;
    GenRc newGenRc;
    do {
        oldGenRc = *genRcPtr;
        newGenRc = oldGenRc;

        newGenRc.alive = false;

        // TODO: Check that gen hasn't changed and that rc > 0.
    } while (!atomic_compare_exchange_weak(genRcPtr, &oldGenRc, newGenRc));
}

// Statement datatype:

typedef struct Statement {
    // We keep rc at 1 to represent being 'owned' by the database.
    // NO, that doesn't work, because then how do you actually release it from the database? What if multiple ppl release at once?
    _Atomic GenRc genRc;

    // Immutable statement properties:
    // -----

    // Owned by the DB. clause cannot be mutated or invalidated while
    // rc > 0.
    Clause* clause;

    // Used for debugging (and stack traces for When bodies).
    char sourceFileName[100];
    int sourceLineNumber;
    pthread_mutex_t sourceMutex;

    // Mutable statement properties:
    // -----

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
    _Atomic GenRc genRc;

    // Immutable match properties:

    pthread_t workerThread;

    // Mutable match properties:

    // isCompleted is set to true once the Tcl evaluation that builds
    // the match is completed. As long as isCompleted is false,
    // workerThread is subject to termination signal (SIGUSR1) if the
    // match is removed.
    _Atomic bool isCompleted;

    struct {
        void (*fn)(void*);
        void* arg;
    } destructors[10];
    pthread_mutex_t destructorsMutex;

    // ListOfEdgeTo StatementRef. Used for removal.
    ListOfEdgeTo* childStatements;
    pthread_mutex_t childStatementsMutex;
} Match;

// Database datatypes:

typedef struct Hold {
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
    pthread_mutex_t holdsMutex;
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
static void listOfEdgeToDefragment(ListEdgeCheckerFn checker, void* checkerArg,
                                   ListOfEdgeTo** listPtr);
// Takes a double pointer to list because it may move the list to grow
// it (requiring replacement of the original pointer). checker is used
// to discard any edges that have been invalidated if we defragment
// (to prevent unlimited growth of the edge list).
void listOfEdgeToAdd(ListEdgeCheckerFn checker, void* checkerArg,
                     ListOfEdgeTo** listPtr, uint64_t to) {
    if ((*listPtr)->nEdges == (*listPtr)->capacityEdges) {
        // We've run out of edge slots at the end of the
        // list. Try defragmenting the list.
        listOfEdgeToDefragment(checker, checkerArg, listPtr);
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
// nEdges accordingly. Discards any edges for which checker(edge) is
// false.
//
// Defragmentation is necessary to prevent continual growth of
// the statement edgelist if you keep adding and removing
// edges on the same statement.
static void listOfEdgeToDefragment(ListEdgeCheckerFn checker, void* checkerArg,
                                   ListOfEdgeTo** listPtr) {
    // Copy all non-EMPTY edges into a new edgelist.
    ListOfEdgeTo* list = calloc(SIZEOF_LIST_OF_EDGE_TO((*listPtr)->capacityEdges), 1);
    size_t nEdges = 0;
    for (size_t i = 0; i < (*listPtr)->nEdges; i++) {
        uint64_t edge = (*listPtr)->edges[i];
        // Also validate edge (is it a valid match / statement?)
        if (edge != 0 && checker(checkerArg, edge)) {
            list->edges[nEdges++] = edge;
        }
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
    // Walk through each child statement and remove this match as a
    // parent of that statement.
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

    // Fire any destructors.
    pthread_mutex_lock(&match->destructorsMutex);
    for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
        if (match->destructors[i].fn != NULL) {
            match->destructors[i].fn(match->destructors[i].arg);
            match->destructors[i].fn = NULL;
        }
    }
    pthread_mutex_unlock(&match->destructorsMutex);
}

////////////////////////////////////////////////////////////
// Statement:
////////////////////////////////////////////////////////////

Statement* statementAcquire(Db* db, StatementRef ref) {
    if (ref.idx == 0) { return NULL; }

    Statement* s = &db->statementPool[ref.idx];
    if (genRcAcquire(&s->genRc, ref.gen)) {
        return s;
    }
    return NULL;
}
Statement* statementUnsafeGet(Db* db, StatementRef ref) {
    if (ref.idx == 0) { return NULL; }
    return &db->statementPool[ref.idx];
}
void statementRelease(Db* db, Statement* stmt) {
    if (genRcRelease(&stmt->genRc)) {
        stmt->parentCount = 0;
        free(stmt->childMatches);
        stmt->childMatches = NULL;

#ifdef FOLK_TRACE
        // Don't remove the clause; we want the trace to be able to
        // find it, and we don't want to reuse the slot.
#else
        Clause* stmtClause = statementClause(stmt);
        for (int i = 0; i < stmtClause->nTerms; i++) {
            free(stmtClause->terms[i]);
        }
        free(stmtClause);

        // Marks this statement slot as being fully free and ready for
        // reuse.
        stmt->clause = NULL;
#endif
    }
}

bool statementCheck(Db* db, StatementRef ref) {
    Statement* s = &db->statementPool[ref.idx];
    GenRc genRc = s->genRc;
    return ref.gen >= 0 && ref.gen == genRc.gen;
}

StatementRef statementRef(Db* db, Statement* stmt) {
    GenRc genRc = stmt->genRc;
    return (StatementRef) {
        .gen = genRc.gen,
        .idx = stmt - &db->statementPool[0]
    };
}

// Creates a new statement. Internal helper for the DB, not callable
// from the outside (they need to insert into the DB as a complete
// operation). Note: clause ownership transfers to the DB, which then
// becomes responsible for freeing it. 
static StatementRef statementNew(Db* db, Clause* clause,
                                 char* sourceFileName,
                                 int sourceLineNumber) {
    StatementRef ret;
    Statement* stmt = NULL;
    // Look for a free statement slot to use:
    while (1) {
        int32_t idx = db->statementPoolNextIdx++;
        if (idx == 0) { continue; }
        stmt = &db->statementPool[idx];

        GenRc oldGenRc = stmt->genRc;
        GenRc newGenRc = oldGenRc;
        ret = (StatementRef) { .gen = newGenRc.gen, .idx = idx };

        if (oldGenRc.rc == 0 && stmt->clause == NULL) {
            newGenRc.alive = true;
            if (atomic_compare_exchange_weak(&stmt->genRc, 
                                             &oldGenRc, newGenRc)) {
                break;
            }
        }
    }
    // We should have exclusive access to stmt right now, because its
    // rc is 1 but it's not pointed to by any ref or pointer other
    // than the one here.

    stmt->clause = clause;

    stmt->parentCount = 1;
    stmt->childMatches = listOfEdgeToNew(8);
    pthread_mutex_init(&stmt->childMatchesMutex, NULL);

    snprintf(stmt->sourceFileName, sizeof(stmt->sourceFileName),
             "%s", sourceFileName);
    stmt->sourceLineNumber = sourceLineNumber;

    return ret;
}
Clause* statementClause(Statement* stmt) { return stmt->clause; }

char* statementSourceFileName(Statement* stmt) {
    return stmt->sourceFileName;
}
int statementSourceLineNumber(Statement* stmt) {
    return stmt->sourceLineNumber;
}

// TODO: do we use this? remove?
void statementRemoveChildMatch(Statement* stmt, MatchRef to) {
    listOfEdgeToRemove(stmt->childMatches, to.val);
}

static bool matchChecker(void* db, uint64_t ref) {
    return matchCheck((Db*) db, (MatchRef) { .val = ref });
}
void statementAddChildMatch(Db* db, Statement* stmt, MatchRef child) {
    listOfEdgeToAdd(&matchChecker, db,
                    &stmt->childMatches, child.val);
}
void statementAddParent(Statement* stmt) { stmt->parentCount++; }
void statementRemoveParentAndMaybeRemoveSelf(Db* db, Statement* stmt) {
    /* printf("statementRemoveParentAndMaybeRemoveSelf: s%d:%d\n", */
    /*        stmt - &db->statementPool[0], stmt->gen); */
    if (--stmt->parentCount == 0) {
        genRcMarkAsDead(&stmt->genRc);

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
    if (genRcAcquire(&m->genRc, ref.gen)) {
        return m;
    } else {
        return NULL;
    }
}
void matchRelease(Db* db, Match* match) {
    if (genRcRelease(&match->genRc)) {
        reactToRemovedMatch(db, match);

        free(match->childStatements);
        match->childStatements = NULL;
    }
}

bool matchCheck(Db* db, MatchRef ref) {
    Match* m = &db->matchPool[ref.idx];
    GenRc genRc = m->genRc;
    return ref.gen >= 0 && ref.gen == genRc.gen;
}

MatchRef matchRef(Db* db, Match* match) {
    GenRc genRc = match->genRc;
    return (MatchRef) {
        .gen = genRc.gen,
        .idx = match - &db->matchPool[0]
    };
}

static MatchRef matchNew(Db* db, pthread_t workerThread) {
    MatchRef ret;
    Match* match = NULL;
    // Look for a free match slot to use:
    while (1) {
        int32_t idx = db->matchPoolNextIdx++;
        if (idx == 0) { continue; }
        match = &db->matchPool[idx];
        
        GenRc oldGenRc = match->genRc;
        GenRc newGenRc = oldGenRc;
        ret = (MatchRef) { .gen = newGenRc.gen, .idx = idx };

        if (oldGenRc.rc == 0 && match->childStatements == NULL) {
            newGenRc.alive = true;
            if (atomic_compare_exchange_weak(&match->genRc, 
                                             &oldGenRc, newGenRc)) {
                break;
            }
        }
    }

    // We should have exclusive access to match right now.

    match->childStatements = listOfEdgeToNew(8);
    pthread_mutex_init(&match->childStatementsMutex, NULL);
    match->workerThread = workerThread;
    match->isCompleted = false;
    for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
        match->destructors[i].fn = NULL;
    }
    pthread_mutex_init(&match->destructorsMutex, NULL);

    return ret;
}

static bool statementChecker(void* db, uint64_t ref) {
    return statementCheck((Db*) db, (StatementRef) { .val = ref });
}
void matchAddChildStatement(Db* db, Match* match, StatementRef child) {
    listOfEdgeToAdd(statementChecker, db,
                    &match->childStatements, child.val);
}
void matchAddDestructor(Match* m, void (*fn)(void*), void* arg) {
    pthread_mutex_lock(&m->destructorsMutex);
    int i;
    for (i = 0; i < sizeof(m->destructors)/sizeof(m->destructors[0]); i++) {
        if (m->destructors[i].fn == NULL) {
            m->destructors[i].fn = fn;
            m->destructors[i].arg = arg;
            break;
        }
    }
    pthread_mutex_unlock(&m->destructorsMutex);
    if (i == 10) {
        fprintf(stderr, "matchAddDestructor: Failed\n"); exit(1);
    }
}

void matchCompleted(Match* match) {
    match->isCompleted = true;
}
void matchRemoveSelf(Db* db, Match* match) {
    /* printf("matchRemoveSelf: m%ld:%d\n", match - &db->matchPool[0], match->gen); */
    genRcMarkAsDead(&match->genRc);
    reactToRemovedMatch(db, match);

    if (!match->isCompleted) {
        // Signal the match worker thread to terminate the match
        // execution.
        // pthread_kill(match->workerThread, SIGUSR1);
    }
}

////////////////////////////////////////////////////////////
// Database:
////////////////////////////////////////////////////////////

Db* dbNew() {
    Db* ret = calloc(sizeof(Db), 1);

    ret->statementPool[0].genRc = (GenRc) { .gen = -1, .rc = 0 };
    ret->statementPoolNextIdx = 1;

    ret->matchPool[0].genRc = (GenRc) { .gen = -1, .rc = 0 };
    ret->matchPoolNextIdx = 1;

    ret->clauseToStatementId = trieNew();
    pthread_mutex_init(&ret->clauseToStatementIdMutex, NULL);

    pthread_mutex_init(&ret->holdsMutex, NULL);

    return ret;
}

// Used by trie-graph.folk. Avoid if you can.
void dbLockClauseToStatementId(Db* db) {
    pthread_mutex_lock(&db->clauseToStatementIdMutex);
}
Trie* dbGetClauseToStatementId(Db* db) {
    return db->clauseToStatementId;
}
void dbUnlockClauseToStatementId(Db* db) {
    pthread_mutex_unlock(&db->clauseToStatementIdMutex);
}

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

// What happens if the parent match is removed at some point?  How do
// we ensure that either this statement is retracted or it never
// appears?
StatementRef dbInsertOrReuseStatement(Db* db, Clause* clause,
                                      char* sourceFileName, int sourceLineNumber,
                                      MatchRef parentMatchRef) {
    pthread_mutex_lock(&db->clauseToStatementIdMutex);

    // Is this clause already present among the existing statements?
    StatementRef existingRefs[10];
    int existingRefsCount = trieLookupLiteral(db->clauseToStatementId, clause,
                                              (uint64_t*) existingRefs,
                                              sizeof(existingRefs)/sizeof(existingRefs[0]));

    // Note that we're still holding the clauseToStatementId lock.

    Match* parent = matchAcquire(db, parentMatchRef);
    if (!matchRefIsNull(parentMatchRef) && parent == NULL) {
        // Parent match has been invalidated -- abort!
        pthread_mutex_unlock(&db->clauseToStatementIdMutex);
        return STATEMENT_REF_NULL;
    }
    if (existingRefsCount == 0) {
        // The clause doesn't exist in a statement yet. Make the new
        // statement.

        // We need to keep the clauseToStatementId trie locked until
        // we've added the new statement, so that no one else also
        // does the same check, gets 0 existing refs, releases the
        // lock, and then adds the new statement at the same time (so
        // we end up with 2 copies).

        StatementRef ref = statementNew(db, clause,
                                        sourceFileName,
                                        sourceLineNumber);
        db->clauseToStatementId = trieAdd(db->clauseToStatementId, clause, ref.val);

        pthread_mutex_unlock(&db->clauseToStatementIdMutex);

        if (parent) {
            matchAddChildStatement(db, parent, ref);
            matchRelease(db, parent);
        }
        return ref;
    }

    Statement* stmt;
    if (existingRefsCount == 1 && (stmt = statementAcquire(db, existingRefs[0]))) {
        // The clause already exists. We'll add the parents to the
        // existing statement instead of making a new statement.

        // TODO: Update the sourceFileName and sourceLineNumber to
        // reflect this parent (this isn't quite correct either but
        // better than nothing).

        // We unlock the trie after acquiring the statement.
        pthread_mutex_unlock(&db->clauseToStatementIdMutex);

        /* printf("Reuse: (%s)\n", clauseToString(clause)); */

        // FIXME: What if the parent has/will be destroyed?
        if (parent) {
            statementAddParent(stmt);
            matchAddChildStatement(db, parent, existingRefs[0]);
            matchRelease(db, parent);
        }
        statementRelease(db, stmt);
        return STATEMENT_REF_NULL;
    }

    // Invariant has been violated: somehow we have 2+ copies of
    // the same clause already in the db?
    fprintf(stderr, "Error: Clause duplicate (existingRefsCount = %d) (%.100s)\n",
            existingRefsCount,
            clauseToString(clause)); exit(1);
}

Match* dbInsertMatch(Db* db, size_t nParents, StatementRef parents[],
                     pthread_t workerThread) {
    MatchRef ref = matchNew(db, workerThread);
    /* printf("dbInsertMatch: m%d:%d <- ", ref.idx, ref.gen); */
    Match* match = matchAcquire(db, ref);
    for (size_t i = 0; i < nParents; i++) {
        /* printf("s%d:%d ", parents[i].idx, parents[i].gen); */
        Statement* parent = statementAcquire(db, parents[i]);
        if (parent) {
            pthread_mutex_lock(&parent->childMatchesMutex);
            statementAddChildMatch(db, parent, ref);
            pthread_mutex_unlock(&parent->childMatchesMutex);

            statementRelease(db, parent);
        } else {
            // TODO: The parent is dead; we should abort/reverse this
            // whole thing.
            /* printf("dbInsertMatch: parent stmt was invalidated\n"); */
            matchRelease(db, match);
            return NULL;
        }
    }
    /* printf("\n"); */
    return match;
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
                             char* sourceFileName, int sourceLineNumber,
                             StatementRef* outOldStatement) {
    if (outOldStatement) { *outOldStatement = STATEMENT_REF_NULL; }

    pthread_mutex_lock(&db->holdsMutex);

    Hold* hold = NULL;
    for (int i = 0; i < sizeof(db->holds)/sizeof(db->holds[0]); i++) {
        if (db->holds[i].key != NULL && strcmp(db->holds[i].key, key) == 0) {
            hold = &db->holds[i];
            break;
        }
    }
    if (hold == NULL) {
        for (int i = 0; i < sizeof(db->holds)/sizeof(db->holds[0]); i++) {
            if (db->holds[i].key == NULL) {
                hold = &db->holds[i];
                hold->key = key;
                break;
            }
        }
    }

    if (hold == NULL) {
        fprintf(stderr, "dbHoldStatement: Ran out of hold slots\n");
        exit(1);
    }

    if (version < 0) {
        version = hold->version + 1;
    }
    if (version > hold->version) {
        StatementRef oldStmt = hold->statement;
        // TODO: Should we accept a StatementRef and enforce that
        // is what gets removed?
        Statement* oldStmtPtr = statementAcquire(db, oldStmt);
        if (oldStmtPtr && clauseIsEqual(clause, statementClause(oldStmtPtr))) {
            statementRelease(db, oldStmtPtr);
            pthread_mutex_unlock(&db->holdsMutex);
            return STATEMENT_REF_NULL;
        }

        hold->version = version;

        StatementRef newStmt = dbInsertOrReuseStatement(db, clause,
                                                        sourceFileName,
                                                        sourceLineNumber,
                                                        MATCH_REF_NULL);
        hold->statement = newStmt;

        uint64_t results[10];
        size_t maxResults = sizeof(results)/sizeof(results[0]);

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

        pthread_mutex_unlock(&db->holdsMutex);
        return newStmt;
    } else {
        // The new version is older than the version already in the
        // hold, so we just shouldn't do anything / we shouldn't
        // install the new statement.
        pthread_mutex_unlock(&db->holdsMutex);
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

