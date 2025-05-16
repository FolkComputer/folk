#ifndef DB_H
#define DB_H

#include <pthread.h>

#include "trie.h"

typedef struct Statement Statement;
typedef struct Match Match;
typedef struct Db Db;

typedef struct Destructor {
    void (*fn)(void*);
    void* arg;
} Destructor;

// Refs are _weak_ references, meaning that the thing they are
// pointing at may be invalid. A ref {0, 0} is always a null reference
// (to enforce this, we set aside idx = 0 to never be a usable slot
// and to always have gen = UINT32_MAX - 1). The null reference can be
// used as a return sentinel.

typedef union StatementRef {
    struct { int32_t gen; uint32_t idx; };
    uint64_t val;
} StatementRef;
#define STATEMENT_REF_NULL ((StatementRef) { .gen = 0, .idx = 0 })
#define statementRefIsNull(ref) ((ref).idx == 0)

typedef union MatchRef {
    struct { int32_t gen; uint32_t idx; };
    uint64_t val;
} MatchRef;
#define MATCH_REF_NULL ((MatchRef) { .gen = 0, .idx = 0 })
#define matchRefIsNull(ref) ((ref).idx == 0)

// Statement
// ---------

// The acquire function validates the ref and gives you a valid
// pointer, or NULL if the ref is invalid. It increments the
// statement's internal pointer counter so that it cannot be freed &
// its gen and clause remain immutable.
Statement* statementAcquire(Db* db, StatementRef ref);
void statementRelease(Db* db, Statement* stmt);

Statement* statementUnsafeGet(Db* db, StatementRef ref);

bool statementCheck(Db* db, StatementRef ref);

StatementRef statementRef(Db* db, Statement* stmt);

Clause* statementClause(Statement* stmt);
char* statementSourceFileName(Statement* stmt);
int statementSourceLineNumber(Statement* stmt);

bool statementHasOtherIncompleteChildMatch(Db* db, Statement* stmt,
                                           MatchRef otherThan);

void statementIncrParentCount(Statement* stmt);
void statementDecrParentCountAndMaybeRemoveSelf(Db* db, Statement* stmt);
void statementRemoveSelf(Db* db, Statement* stmt, bool doDeindex);

// Match
// -----

// The acquire function validates the ref and gives you a valid
// pointer, or NULL if the ref is invalid. It increments the match's
// internal pointer counter so that it cannot be freed & its gen
// remains immutable.
Match* matchAcquire(Db* db, MatchRef match);
void matchRelease(Db* db, Match* m);

bool matchCheck(Db* db, MatchRef ref);

void matchAddDestructor(Match* m, Destructor d);

void matchCompleted(Match* m);
void matchRemoveSelf(Db* db, Match* m);

MatchRef matchRef(Db* db, Match* m);

// Db
// --

typedef struct Clause Clause;

Db* dbNew();
const Trie* dbGetClauseToStatementRef(Db* db);

typedef struct ResultSet {
    size_t nResults;
    StatementRef results[];
} ResultSet;
#define SIZEOF_RESULTSET(NRESULTS) (sizeof(ResultSet) + (NRESULTS)*sizeof(Statement*))
// You're querying a snapshot of whatever statements happened to be in
// the trie in the moment. The StatementRefs in it may already be
// invalid by the time dbQuery returns. Caller must free the returned
// ResultSet*.
ResultSet* dbQuery(Db* db, Clause* pattern);

// Note: once you call this, clause ownership transfers to the DB,
// which then becomes responsible for freeing it later. Pass a null
// MatchRef if this is an assertion. Returns a null StatementRef if no
// new statement was created. 
StatementRef dbInsertOrReuseStatement(Db* db, Clause* clause, long keepMs,
                                      Destructor destructor,
                                      const char* sourceFileName, int sourceLineNumber,
                                      MatchRef parent,
                                      StatementRef* outReusedStatementRef);

// Call when you're about to begin a match (i.e., evaluating the body
// of a When) -- creates the Match object that you'll attach any
// emitted Statements to. The worker thread is stored with the Match
// so that the thread can be interrupted if the match is
// destroyed. The Match is returned acquired and needs to be released
// by the caller.
Match* dbInsertMatch(Db* db, int nParents, StatementRef parents[],
                     int workerThreadIndex);

void dbRetractStatements(Db* db, Clause* pattern);

// If version is negative, then this statement will always stomp the
// previous version. Note: once you call this, clause ownership
// transfers to the DB, and it is responsible for freeing the clause
// later.
StatementRef dbHoldStatement(Db* db,
                             const char* key, int64_t version,
                             Clause* clause, long keepMs,
                             Destructor destructor,
                             const char* sourceFileName, int sourceLineNumber,
                             StatementRef* outOldStatement);

#endif
