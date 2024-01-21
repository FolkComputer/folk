#ifndef DB_H
#define DB_H

#include "trie.h"

typedef struct Statement Statement;
typedef struct Match Match;
typedef struct Clause Clause;

Clause* clause(char* first, ...);
void dbInsert(Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement);

void testInit();
Trie* testGetClauseToStatementId();
void testAssert(Clause* clause);

#endif
