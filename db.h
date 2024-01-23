#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
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

Clause* clause(char* first, ...);
void dbInsert(Db* db,
              Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement);

// Assert creates a statement without parents, a premise.
Statement* dbAssert(Db* db, Clause* clause);

#endif
