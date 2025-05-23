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

#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include "common.h"
#include "trie.h"
#include "epoch.h"
#include "sysmon.h"
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

    // The object also cannot be freed/invalidated as long as alive is
    // true; alive indicates that the object is alive in the database
    // (has supporting parent).
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
    bool callerIsLastReleaser = false;
    do {
        oldGenRc = *genRcPtr;
        newGenRc = oldGenRc;

        --newGenRc.rc;
        callerIsLastReleaser = !oldGenRc.alive && (newGenRc.rc == 0);
        if (callerIsLastReleaser) {
            newGenRc.gen++;
        }

    } while (!atomic_compare_exchange_weak(genRcPtr, &oldGenRc, newGenRc));
    return callerIsLastReleaser;
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

static void destructorTryRun(Destructor* f) {
    if (f->fn != NULL) {
        f->fn(f->arg);
        f->fn = NULL;
    }
}

// Statement datatype:

typedef struct Statement {
    _Atomic GenRc genRc;

    // Immutable statement properties:
    // -----

    // Owned by the DB. clause cannot be mutated or invalidated while
    // rc > 0.
    Clause* clause;

    // If the statement is removed, we wait keepMs milliseconds before
    // removing its child matches.
    _Atomic long keepMs;

    Destructor destructor;

    // Used for debugging (and stack traces for When bodies).
    char sourceFileName[100];
    int sourceLineNumber;

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

    int workerThreadIndex;

    // Mutable match properties:

    // isCompleted is set to true once the Tcl evaluation that builds
    // the match is completed. As long as isCompleted is false,
    // workerThread is subject to termination signal (SIGUSR1) if the
    // match is removed.
    _Atomic bool isCompleted;

    Destructor destructors[10];
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
    const Trie* _Atomic clauseToStatementRef;

    // One for each Hold key, which always stores the highest-version
    // held statement for that key. We keep this map so that we can
    // overwrite out-of-date Holds for a key as soon as a newer one
    // comes in, without having to actually emit and react to the
    // statement.
    Hold holds[256];
    Mutex holdsMutex;
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

static void statementDestroy(Statement* stmt);
void statementRelease(Db* db, Statement* stmt) {
    if (genRcRelease(&stmt->genRc)) {
        statementDestroy(stmt);
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
static StatementRef statementNew(Db* db, Clause* clause, long keepMs,
                                 Destructor destructor,
                                 const char* sourceFileName,
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
    stmt->keepMs = keepMs;
    stmt->destructor = destructor;

    stmt->parentCount = 1;
    stmt->childMatches = listOfEdgeToNew(8);

    pthread_mutexattr_t mta;
    pthread_mutexattr_init(&mta);
    pthread_mutexattr_settype(&mta, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&stmt->childMatchesMutex, &mta);
    pthread_mutexattr_destroy(&mta);

    snprintf(stmt->sourceFileName, sizeof(stmt->sourceFileName),
             "%s", sourceFileName);
    stmt->sourceLineNumber = sourceLineNumber;

    return ret;
}
static void statementDestroy(Statement* stmt) {
    stmt->parentCount = 0;
    // They should have removed the children first.
    assert(stmt->childMatches == NULL);

    Clause* stmtClause = statementClause(stmt);
    // Marks this statement slot as being fully free and ready for
    // reuse.
    stmt->clause = NULL;

    /* TracyCFreeS(stmt, 4); */
    clauseFree(stmtClause);

    destructorTryRun(&stmt->destructor);
}

Clause* statementClause(Statement* stmt) { return stmt->clause; }

char* statementSourceFileName(Statement* stmt) {
    return stmt->sourceFileName;
}
int statementSourceLineNumber(Statement* stmt) {
    return stmt->sourceLineNumber;
}

bool statementHasOtherIncompleteChildMatch(Db* db, Statement* stmt, MatchRef otherThan) {
    bool hasIncompleteChildMatch = false;

    pthread_mutex_lock(&stmt->childMatchesMutex);
    if (stmt->childMatches == NULL) {
        hasIncompleteChildMatch = false; goto done;
    }
    for (size_t i = 0; i < stmt->childMatches->nEdges; i++) {
        MatchRef childRef = { .val = stmt->childMatches->edges[i] };
        if (childRef.val == otherThan.val) { continue; }

        Match* child = matchAcquire(db, childRef);
        if (child != NULL) {
            if (!child->isCompleted) {
                hasIncompleteChildMatch = true;
                matchRelease(db, child);
                goto done;
            } else {
                matchRelease(db, child);
            }
        }
    }
 done:    
    pthread_mutex_unlock(&stmt->childMatchesMutex);
    return hasIncompleteChildMatch;
}

static bool matchChecker(void* db, uint64_t ref) {
    return matchCheck((Db*) db, (MatchRef) { .val = ref });
}
// You must call this with the childMatchesMutex held.
static void statementAddChildMatch(Db* db, Statement* stmt, MatchRef child) {
    listOfEdgeToAdd(&matchChecker, db,
                    &stmt->childMatches, child.val);
}

// Fails to increment parentCount & returns false if parentCount is 0,
// meaning that the statement is in the process of being destroyed by
// someone else and you should back off.
bool statementTryIncrParentCount(Statement* stmt) {
    int oldParentCount;
    int newParentCount;
    do {
        oldParentCount = stmt->parentCount;
        if (oldParentCount == 0) {
            return false;
        }
        newParentCount = oldParentCount + 1;
    } while (!atomic_compare_exchange_weak(&stmt->parentCount, &oldParentCount,
                                           newParentCount));
    return true;
}

void statementDecrParentCountAndMaybeRemoveSelf(Db* db, Statement* stmt) {
    if (stmt->keepMs > 0) {
        if (--stmt->parentCount == 0) {
            // Note that we should have exclusive access to stmt at
            // this point.

            // Prevent future removers now that we've already
            // scheduled removal.
            long keepMs = stmt->keepMs;
            stmt->keepMs = -keepMs;

            // Tentatively trigger a removal in `keepMs` ms, but the
            // statement is still able to be revived in the
            // intervening time.
            sysmonScheduleRemoveAfter(statementRef(db, stmt), keepMs);

            stmt->parentCount++;
        }

    } else if (stmt->keepMs < 0) {
        // We're carrying out a previously-scheduled removal.
        if (--stmt->parentCount == 0) {
            // Note that we should have exclusive access to stmt at
            // this point.
            statementRemoveSelf(db, stmt, true);

        } else {
            // The statement's been revived; restore keepMs.

            // TODO: there's a race here if parentCount gets zeroed
            // without ever getting scheduled for removal.
            stmt->keepMs = -stmt->keepMs;
        }

    } else if (stmt->keepMs == 0) {
        if (--stmt->parentCount == 0) {
            // Note that we should have exclusive access to stmt at
            // this point.
            statementRemoveSelf(db, stmt, true);
        }
    }
}

// Call statementRemoveSelf when ALL of the statement's parents
// (matches or other) are removed (parentCount has hit 0).
void statementRemoveSelf(Db* db, Statement* stmt, bool doDeindex) {
    assert(stmt->parentCount == 0);

    if (doDeindex) {
        uint64_t results[100]; int resultsCount;
        epochBegin();

        const Trie* oldClauseToStatementRef;
        const Trie* newClauseToStatementRef;
        do {
            epochReset();
            oldClauseToStatementRef = db->clauseToStatementRef;
            newClauseToStatementRef =
                trieRemove(db->clauseToStatementRef,
                           epochAlloc, epochFree,
                           stmt->clause,
                           (uint64_t*) results, sizeof(results)/sizeof(results[0]),
                           &resultsCount);
            if (newClauseToStatementRef == oldClauseToStatementRef) {
                break;
            }
        } while (!atomic_compare_exchange_weak(&db->clauseToStatementRef,
                                               &oldClauseToStatementRef,
                                               newClauseToStatementRef));
        epochEnd();
    }

    /* printf("reactToRemovedStatement: s%d:%d (%s)\n", stmt - &db->statementPool[0], stmt->gen, */
    /*        clauseToString(stmt->clause)); */
    pthread_mutex_lock(&stmt->childMatchesMutex);
    ListOfEdgeTo* childMatches = stmt->childMatches;
    assert(childMatches != NULL);
    // Guarantees that no further matches can be added (we would be
    // unable to remove those).
    stmt->childMatches = NULL;
    genRcMarkAsDead(&stmt->genRc);
    pthread_mutex_unlock(&stmt->childMatchesMutex);

    for (size_t i = 0; i < childMatches->nEdges; i++) {
        MatchRef childRef = { .val = childMatches->edges[i] };
        Match* child = matchAcquire(db, childRef);
        if (child != NULL) {
            // The removal of _any_ of a Match's statement parents
            // means the removal of that Match.
            matchRemoveSelf(db, child);
            matchRelease(db, child);
        }
    }
    free(childMatches);
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
        assert(match->childStatements == NULL);
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

static MatchRef matchNew(Db* db, int workerThreadIndex) {
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

    pthread_mutexattr_t mta;
    pthread_mutexattr_init(&mta);
    pthread_mutexattr_settype(&mta, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&match->childStatementsMutex, &mta);
    pthread_mutexattr_destroy(&mta);

    match->workerThreadIndex = workerThreadIndex;
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
// You must call this with the childStatementsMutex held.
static void matchAddChildStatement(Db* db, Match* match, StatementRef child) {
    listOfEdgeToAdd(statementChecker, db,
                    &match->childStatements, child.val);
}
void matchAddDestructor(Match* m, Destructor d) {
    pthread_mutex_lock(&m->destructorsMutex);
    int destructorsMax = sizeof(m->destructors)/sizeof(m->destructors[0]);
    int i;
    for (i = 0; i < destructorsMax; i++) {
        if (m->destructors[i].fn == NULL) {
            m->destructors[i] = d;
            break;
        }
    }
    pthread_mutex_unlock(&m->destructorsMutex);
    if (i == destructorsMax) {
        fprintf(stderr, "matchAddDestructor: Failed\n"); exit(1);
    }
}

void matchCompleted(Match* match) {
    match->isCompleted = true;
}
// Call matchRemoveSelf when ANY of the match's parent statements is
// removed.
//
// FIXME: Make this thread-safe (if called by multiple removers at the
// same time, it shouldn't double-free).
extern ThreadControlBlock threads[];
extern void traceItem(char* buf, size_t bufsz, WorkQueueItem item);
void matchRemoveSelf(Db* db, Match* match) {
    /* assert(match > &db->matchPool[0] && match < &db->matchPool[65536]); */

    // Walk through each child statement and remove this match as a
    // parent of that statement.
    pthread_mutex_lock(&match->childStatementsMutex);
    ListOfEdgeTo* childStatements = match->childStatements;
    if (childStatements == NULL) {
        // Someone else has done / is doing removal. Abort.
        pthread_mutex_unlock(&match->childStatementsMutex);
        return;
    }
    // This blocks further child statements from being added to this
    // match (if they were added, then we wouldn't be able to remove
    // them).
    match->childStatements = NULL;
    genRcMarkAsDead(&match->genRc);
    pthread_mutex_unlock(&match->childStatementsMutex);

    for (size_t i = 0; i < childStatements->nEdges; i++) {
        StatementRef childRef = { .val = childStatements->edges[i] };
        Statement* child = statementAcquire(db, childRef);
        if (child != NULL) {
            statementDecrParentCountAndMaybeRemoveSelf(db, child);
            statementRelease(db, child);
        }
    }
    free(childStatements);

    // Fire any destructors.
    pthread_mutex_lock(&match->destructorsMutex);
    for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
        destructorTryRun(&match->destructors[i]);
    }
    pthread_mutex_unlock(&match->destructorsMutex);

    if (!match->isCompleted) {
        // Signal the match worker thread to terminate the match
        // execution.
        ThreadControlBlock *workerThread = &threads[match->workerThreadIndex];
        if (timestamp_get(workerThread->clockid) - workerThread->currentItemStartTimestamp > 100000000) {
            char buf[10000]; traceItem(buf, sizeof(buf), workerThread->currentItem);
            fprintf(stderr, "KILL (%.100s)\n", buf);
            kill(workerThread->tid, SIGUSR1);
        }
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

    ret->clauseToStatementRef = trieNew();

    mutexInit(&ret->holdsMutex);

    return ret;
}

// Used by trie-graph.folk. Avoid if you can.
void dbLockClauseToStatementRef(Db* db) {
    epochBegin();
}
const Trie* dbGetClauseToStatementRef(Db* db) {
    return db->clauseToStatementRef;
}
void dbUnlockClauseToStatementRef(Db* db) {
    epochEnd();
}

// Query
ResultSet* dbQuery(Db* db, Clause* pattern) {
    ResultSet *resultSet;
    size_t maxResults = 500;
    do {
        resultSet = malloc(SIZEOF_RESULTSET(maxResults));

        epochBegin();
        resultSet->nResults =
            trieLookup(db->clauseToStatementRef, pattern,
                       (uint64_t*) resultSet->results, maxResults);
        epochEnd();

        if (resultSet->nResults < maxResults) {
            break;
        }

        maxResults *= 2;
        if (maxResults > 10 * 1000) {
            fprintf(stderr, "dbQuery: Too many results for query (%s)\n",
                    clauseToString(pattern));
            exit(1);
        }
        free(resultSet);
    } while (true);

    return resultSet;
}

// parentMatch is allowed to be NULL (meaning that no parent match is
// specified; the statement impulse comes directly from Assert! or
// Hold!). If parentMatch is not NULL, then you need to have
// (obviously) acquired the match _and_ to be holding its
// childStatementsMutex when you call this function.
static bool tryReuseStatement(Db* db, Statement* stmt, Match* parentMatch) {
    if (parentMatch != NULL) {
        // TODO: Update the sourceFileName and sourceLineNumber of the
        // stmt to reflect this new parent? (this isn't quite correct
        // either but better than nothing)

        if (!statementTryIncrParentCount(stmt)) {
            // We still want to insert/reuse the statement, but this
            // one is on the way out, so tell the caller to retry.
            return false;
        }

        matchAddChildStatement(db, parentMatch, statementRef(db, stmt));
        return true;
    }

    if (!statementTryIncrParentCount(stmt)) {
        return false;
    } else {
        return true;
    }
}

// Inserts a new statement with clause `clause` & returns a ref to
// that newly created statement & sets outReusedStatementRef to a null
// ref, UNLESS:
// 
//   - a statement is already present with that clause, in which case
//     we increment that statement's parent count & return a null ref
//     & set outReusedStatementRef to the already-present statement
//
//   - parentMatchRef has been invalidated, or its parentMatch has
//     childStatements invalidated, in which case we do nothing &
//     return a null ref & set outReusedStatementRef to a null ref
//     (because the whole situation has been invalidated)
// 
// (both of these mean that the caller shouldn't trigger a reaction,
// since no new statement is being created).
//
// Takes ownership of clause (i.e., you can't touch clause at the
// caller after calling this!).
StatementRef dbInsertOrReuseStatement(Db* db, Clause* clause, long keepMs,
                                      Destructor destructor,
                                      const char* sourceFileName, int sourceLineNumber,
                                      MatchRef parentMatchRef,
                                      StatementRef* outReusedStatementRef) {
#define setReusedStatementRef(_ref) \
    if (outReusedStatementRef != NULL) { \
        *outReusedStatementRef = (_ref); \
    }

    Match* parentMatch = NULL;
    if (!matchRefIsNull(parentMatchRef)) {
        // Need to set up parent match.
        parentMatch = matchAcquire(db, parentMatchRef);
        if (parentMatch == NULL) {
            setReusedStatementRef(STATEMENT_REF_NULL);
            return STATEMENT_REF_NULL; // Abort!
        }

        pthread_mutex_lock(&parentMatch->childStatementsMutex);
        if (parentMatch->childStatements == NULL) {
            pthread_mutex_unlock(&parentMatch->childStatementsMutex);
            matchRelease(db, parentMatch);

            setReusedStatementRef(STATEMENT_REF_NULL);
            return STATEMENT_REF_NULL; // Abort!
        }

        // Given that we have a parent match, if we've reached this
        // point, we now have a guarantee that the parentMatch is
        // acquired and we hold its childStatementsMutex and can add
        // to its childStatements list.
    }

    // Now try to add: the trieAdd operation will atomically detect if
    // the clause is already present.
    //
    // We'll provisionally create a new statement to add.
    // 
    // Also transfers ownership of clause to the DB.
    StatementRef ref = statementNew(db, clause, keepMs, destructor,
                                    sourceFileName, sourceLineNumber);

    epochBegin();
    const Trie* oldClauseToStatementRef;
    const Trie* newClauseToStatementRef;
    do {
        epochReset();
        oldClauseToStatementRef = db->clauseToStatementRef;
        newClauseToStatementRef = trieAdd(oldClauseToStatementRef,
                                          epochAlloc, epochFree,
                                          clause, ref.val);

        if (newClauseToStatementRef == oldClauseToStatementRef) {
            // The statement is possibly already present in the db --
            // trieAdd reported that it did not add anything -- so we
            // should try to reuse the existing statement.
            StatementRef existingRefs[10];
            int existingRefsCount = 
                trieLookupLiteral(oldClauseToStatementRef, clause,
                                  (uint64_t*)existingRefs,
                                  sizeof(existingRefs)/sizeof(existingRefs[0]));
            Statement* stmt;
            if (existingRefsCount == 1 && (stmt = statementAcquire(db, existingRefs[0]))) {
                // This is sort of the expected case. The statement is
                // indeed already present in the db, and we've been
                // able to acquire it.
                //
                // TODO: Warn if keepMs differs between existing and
                // newly-proposed statement?
                if (tryReuseStatement(db, stmt, parentMatch)) {
                    statementRelease(db, stmt);

                    epochReset();
                    epochEnd();

                    // Free the new statement `ref` that we created,
                    // since we won't be using it.
                    Statement* newStmt = statementAcquire(db, ref);
                    newStmt->parentCount = 0;
                    statementRemoveSelf(db, newStmt, false);
                    statementRelease(db, newStmt);

                    if (parentMatch != NULL) {
                        pthread_mutex_unlock(&parentMatch->childStatementsMutex);
                        matchRelease(db, parentMatch);
                    }

                    setReusedStatementRef(existingRefs[0]);
                    return STATEMENT_REF_NULL;
                } else {
                    // Reuse failed, but not for operation-aborting
                    // reasons -- we just need to actually make the
                    // new statement, probably.
                    statementRelease(db, stmt);
                    continue; // Retry.
                }

            } else if (existingRefsCount > 1) {
                // The database invariant has been violated.
                fprintf(stderr, "dbInsertOrReuseStatement: FATAL: "
                        "More than 1 statement with same clause.\n");
                exit(1);
            } else {
                // Something changed and now that duplicate statement
                // is gone (existingRefsCount == 0 or acquire
                // failed). Let's start over and try to add again.
                continue;
            }
        }
    } while (!atomic_compare_exchange_weak(&db->clauseToStatementRef,
                                           &oldClauseToStatementRef,
                                           newClauseToStatementRef));
    epochEnd();

    // OK, we've made a new statement. trieAdd added the statement to
    // the db and we committed the new db.
    if (parentMatch != NULL) {
        matchAddChildStatement(db, parentMatch, ref);

        pthread_mutex_unlock(&parentMatch->childStatementsMutex);
        matchRelease(db, parentMatch);
    }

    setReusedStatementRef(STATEMENT_REF_NULL);
    return ref;

#undef setReusedStatementRef
}

Match* dbInsertMatch(Db* db, int nParents, StatementRef parents[],
                     int workerThreadIndex) {
    MatchRef ref = matchNew(db, workerThreadIndex);
    Match* match = matchAcquire(db, ref);
    assert(match);

    // All parents need to be valid and need to have locked
    // childMatches before we insert the match. Otherwise, abort.
    bool failed = false;

    Statement* parentStatements[nParents];
    memset(parentStatements, 0, sizeof(parentStatements));
    for (int i = 0; i < nParents; i++) {
        parentStatements[i] = statementAcquire(db, parents[i]);
        if (parentStatements[i] == NULL) {
            failed = true; goto done;
        }

        pthread_mutex_lock(&parentStatements[i]->childMatchesMutex);
        if (parentStatements[i]->childMatches == NULL) {
            failed = true; goto done;
        }
    }

    // We have now acquired all parent statements and are holding
    // their childMatchesMutexes, and none have childMatches == NULL.

    // Now we can do the actual insertion.
    for (int i = 0; i < nParents; i++) {
        statementAddChildMatch(db, parentStatements[i], ref);
    }

done:
    for (int i = nParents - 1; i >= 0; i--) {
        if (parentStatements[i] == NULL) {
            continue;
        }
        pthread_mutex_unlock(&parentStatements[i]->childMatchesMutex);
        statementRelease(db, parentStatements[i]);
    }

    if (failed) {
        matchRemoveSelf(db, match);
        matchRelease(db, match);
        return NULL;
    } else {
        return match;
    }
}

void dbRetractStatements(Db* db, Clause* pattern) {
    StatementRef results[500];
    size_t maxResults = sizeof(results)/sizeof(results[0]);

    // TODO: Should we accept a StatementRef and enforce that is what
    // gets removed?
    epochBegin();
    size_t nResults = trieLookup(db->clauseToStatementRef, pattern,
                                 (uint64_t*) results, maxResults);
    epochEnd();

    if (nResults == maxResults) {
        // TODO: Try again with a larger maxResults?
        fprintf(stderr, "dbQuery: Hit max results\n"); exit(1);
    }

    for (size_t i = 0; i < nResults; i++) {
        Statement* stmt = statementAcquire(db, results[i]);

        statementDecrParentCountAndMaybeRemoveSelf(db, stmt);
        statementRelease(db, stmt);
    }
}

// Takes ownership of clause.
StatementRef dbHoldStatement(Db* db,
                             const char* key, int64_t version,
                             Clause* clause, long keepMs,
                             Destructor destructor,
                             const char* sourceFileName, int sourceLineNumber,
                             StatementRef* outOldStatement) {
    if (outOldStatement) { *outOldStatement = STATEMENT_REF_NULL; }

    mutexLock(&db->holdsMutex);

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
                hold->key = strdup(key);
                hold->version = -1;
                break;
            }
        }
    }

    if (hold == NULL) {
        fprintf(stderr, "dbHoldStatement: Ran out of hold slots:\n");
        for (int i = 0; i < sizeof(db->holds)/sizeof(db->holds[0]); i++) {
            fprintf(stderr, "  %d. {%s}\n", i, db->holds[i].key);
        }
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
            mutexUnlock(&db->holdsMutex);
            clauseFree(clause);
            return STATEMENT_REF_NULL;
        }

        StatementRef newStmt = STATEMENT_REF_NULL;
        if (clause->nTerms > 0) {
            hold->version = version;

            StatementRef reusedStatementRef;
            newStmt = dbInsertOrReuseStatement(db, clause, keepMs,
                                               destructor,
                                               sourceFileName,
                                               sourceLineNumber,
                                               MATCH_REF_NULL,
                                               &reusedStatementRef);
            if (!statementRefIsNull(newStmt)) {
                hold->statement = newStmt;
            } else if (!statementRefIsNull(reusedStatementRef)) {
                hold->statement = reusedStatementRef;
            } else {
                fprintf(stderr, "dbHoldStatement: ERROR: Ref neither reused nor created\n");
                exit(1);
            }
        } else {
            clauseFree(clause);
            hold->statement = STATEMENT_REF_NULL;
            hold->key = NULL;
        }


        if (oldStmtPtr) {
            // We deindex (trieRemove) the old statement immediately,
            // but we leave it to the caller to actually destroy the
            // statement itself (and therefore remove all its
            // children).
            epochBegin();

            uint64_t results[10]; int resultsCount;

            const Trie* oldClauseToStatementRef;
            const Trie* newClauseToStatementRef;
            do {
                epochReset();
                oldClauseToStatementRef = db->clauseToStatementRef;
                newClauseToStatementRef =
                    trieRemove(db->clauseToStatementRef,
                               epochAlloc, epochFree,
                               statementClause(oldStmtPtr),
                               (uint64_t*) results, sizeof(results)/sizeof(results[0]),
                               &resultsCount);
                if (newClauseToStatementRef == oldClauseToStatementRef) {
                    break;
                }
            } while (!atomic_compare_exchange_weak(&db->clauseToStatementRef,
                                                   &oldClauseToStatementRef,
                                                   newClauseToStatementRef));
            epochEnd();

            statementRelease(db, oldStmtPtr);
        } else if (oldStmt.idx != 0) {
            fprintf(stderr, "Somehow old statement from Hold (%d:%d) was already removed?\n",
                    oldStmt.idx, oldStmt.gen);
        }

        /* assert(nRemoved == 1); */
        /* assert(results[0] == oldStmt.val); */

        if (outOldStatement) { *outOldStatement = oldStmt; }

        mutexUnlock(&db->holdsMutex);
        return newStmt;
    } else {
        // The new version is older than the version already in the
        // hold, so we just shouldn't do anything / we shouldn't
        // install the new statement.
        mutexUnlock(&db->holdsMutex);
        clauseFree(clause);
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

