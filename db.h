#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
Clause* statementClause(Statement* stmt);

typedef struct Match Match;
typedef enum { EDGE_EMPTY, EDGE_PARENT, EDGE_CHILD } EdgeType;
typedef struct ListOfEdgeToMatch {
    size_t capacityEdges;
    size_t nEdges; // This is an estimate.
    struct {
        EdgeType type;
        Match* to;
    } edges[];
} ListOfEdgeToMatch;
// The returned object is only _borrowed_ from the DB and should not
// be freed or mutated by the caller.
ListOfEdgeToMatch* statementEdges(Statement* stmt);

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

// The Clause* and all term strings inside the Clause are copied so
// that the database owns them.
void dbInsertStatement(Db* db,
                       Clause* clause,
                       size_t nParents, Match* parents[],
                       Statement** outStatement, bool* outIsNewStatement);
void dbInsertMatch(Db* db,
                   size_t nParents, Statement* parents[],
                   Match** outMatch);

ResultSet* dbRemoveStatements(Db* db, Clause* pattern);

// Assert creates a statement without parents, a premise.
Statement* dbAssert(Db* db, Clause* clause);

#endif
