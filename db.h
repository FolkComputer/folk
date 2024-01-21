#ifndef DB_H
#define DB_H

typedef struct Statement Statement;
typedef struct Match Match;
typedef struct Clause Clause;

Clause* clause(char* first, ...);
void dbInsert(Clause* clause,
              size_t nParents, Match* parents[],
              Statement** outStatement, bool* outIsNewStatement);

void testInit();
void testAssert(Clause* clause);

#endif
