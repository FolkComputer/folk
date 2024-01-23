#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct ListOfEdgeTo ListOfEdgeTo;
typedef struct Statement {
    Clause* clause;
    bool collectNeedsRecollect;

    // List of edges to parent & child Matches:
    ListOfEdgeTo* edges; // Allocated separately so it can be resized.
} Statement;

typedef struct Match Match;
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

void dbInsert(Db* db,
              Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement);

// Assert creates a statement without parents, a premise.
Statement* dbAssert(Db* db, Clause* clause);

#endif
