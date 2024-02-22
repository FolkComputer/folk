#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
typedef struct Match Match;
typedef struct Db Db;

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
#define statementRefIsNonNull(ref) ((ref).idx != 0)

typedef union MatchRef {
    struct { int32_t gen; uint32_t idx; };
    uint64_t val;
} MatchRef;
#define MATCH_REF_NULL ((MatchRef) { .gen = 0, .idx = 0 })
#define matchRefIsNonNull(ref) ((ref).idx != 0)

// The acquire function validates the ref and gives you a valid
// pointer, or NULL if the ref is invalid. It also acquires the
// statement lock.
Statement* statementAcquire(Db* db, StatementRef stmt);
void statementRelease(Statement* stmt);

StatementRef statementRef(Db* db, Statement* stmt);

// The acquire function validates the ref and gives you a valid
// pointer, or NULL if the ref is invalid. It also acquires the match
// lock.
Match* matchAcquire(Db* db, MatchRef match);
void matchRelease(Match* m);

MatchRef matchRef(Db* db, Match* m);

Clause* statementClause(Statement* stmt);
void statementFree(Statement* stmt);

void matchFree(Match* match);

typedef enum { EDGE_EMPTY, EDGE_PARENT, EDGE_CHILD } EdgeType;

typedef struct StatementEdgeIterator {
    Statement* stmt;
    int idx;
} StatementEdgeIterator;
StatementEdgeIterator statementEdgesBegin(Statement* stmt);
StatementEdgeIterator statementEdgesNext(StatementEdgeIterator it);
bool statementEdgesIsEnd(StatementEdgeIterator it);
EdgeType statementEdgeType(StatementEdgeIterator it);
MatchRef statementEdgeMatch(StatementEdgeIterator it);

int statementRemoveEdgeToMatch(Statement* stmt, EdgeType type, MatchRef to);

typedef struct MatchEdgeIterator {
    Match* match;
    int idx;
} MatchEdgeIterator;
MatchEdgeIterator matchEdgesBegin(Match* match);
MatchEdgeIterator matchEdgesNext(MatchEdgeIterator it);
bool matchEdgesIsEnd(MatchEdgeIterator it);
EdgeType matchEdgeType(MatchEdgeIterator it);
StatementRef matchEdgeStatement(MatchEdgeIterator it);

typedef struct Clause Clause;

Db* dbNew();
Trie* dbGetClauseToStatementId(Db* db);

typedef struct ResultSet {
    size_t nResults;
    StatementRef results[];
} ResultSet;
#define SIZEOF_RESULTSET(NRESULTS) (sizeof(ResultSet) + (NRESULTS)*sizeof(Statement*))
// dbQuery only temporarily locks the trie while doing the query, so
// you're getting a snapshot of whatever statements happened to be in
// there in the moment. The StatementRefs in it may already be invalid
// by the time dbQuery returns. Caller must free the returned
// ResultSet*.
ResultSet* dbQuery(Db* db, Clause* pattern);

// Note: once you call this, clause ownership transfers to the DB,
// which then becomes responsible for freeing it later.  Returns a
// StatementRef with gen -1 if no new statement was created.
StatementRef dbInsertStatement(Db* db, Clause* clause,
                               size_t nParents, MatchRef parents[]);
MatchRef dbInsertMatch(Db* db,
                       size_t nParents, StatementRef parents[]);

// Caller must free the returned ResultSet*.
ResultSet* dbQueryAndDeindexStatements(Db* db, Clause* pattern);

// If version is negative, then this statement will always stomp the
// previous version. Note: once you call this, clause and key
// ownership transfer to the DB, and it is responsible for freeing
// them later.
StatementRef dbHoldStatement(Db* db,
                             const char* key, int64_t version,
                             Clause* clause,
                             StatementRef* outOldStatement);

#endif
