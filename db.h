#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
typedef struct Match Match;
typedef struct Clause Clause;
typedef struct Db Db;

Db* dbNew();
Trie* dbGetClauseToStatementId(Db* db);

Clause* clause(char* first, ...);
void dbInsert(Db* db,
              Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement);

void testAssert(Db* db, Clause* clause);

#endif
