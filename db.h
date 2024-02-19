#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
Clause* statementClause(Statement* stmt);
void statementFree(Statement* stmt);

typedef struct Match Match;
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
Match* statementEdgeMatch(StatementEdgeIterator it);

int statementRemoveEdgeToMatch(Statement* stmt, EdgeType type, Match* to);

typedef struct MatchEdgeIterator {
    Match* match;
    int idx;
} MatchEdgeIterator;
MatchEdgeIterator matchEdgesBegin(Match* match);
MatchEdgeIterator matchEdgesNext(MatchEdgeIterator it);
bool matchEdgesIsEnd(MatchEdgeIterator it);
EdgeType matchEdgeType(MatchEdgeIterator it);
Statement* matchEdgeStatement(MatchEdgeIterator it);

typedef struct Clause Clause;
typedef struct Db Db;

Db* dbNew();
Trie* dbGetClauseToStatementId(Db* db);

typedef struct ResultSet {
    size_t nResults;
    Statement* results[];
} ResultSet;
#define SIZEOF_RESULTSET(NRESULTS) (sizeof(ResultSet) + (NRESULTS)*sizeof(Statement*))
// Caller must free the returned ResultSet*.
ResultSet* dbQuery(Db* db, Clause* pattern);

// Note: once you call this, clause ownership transfers to the DB,
// which then becomes responsible for freeing it later.
void dbInsertStatement(Db* db,
                       Clause* clause,
                       size_t nParents, Match* parents[],
                       Statement** outStatement, bool* outIsNewStatement);
void dbInsertMatch(Db* db,
                   size_t nParents, Statement* parents[],
                   Match** outMatch);

ResultSet* dbQueryAndDeindexStatements(Db* db, Clause* pattern);

// Assert creates a statement without parents, a premise.
Statement* dbAssert(Db* db, Clause* clause);

// If version is negative, then this statement will always stomp the
// previous version. Note: once you call this, clause and key
// ownership transfer to the DB, and it is responsible for freeing
// them later.
void dbHoldStatement(Db* db,
                     const char* key, int64_t version,
                     Clause* clause,
                     Statement** outStatement, bool* outIsNewStatement,
                     Statement** outOldStatement);

#endif
