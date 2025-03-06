#ifndef CACHE_H
#define CACHE_H

#define JIM_EMBEDDED
#include <jim.h>

// LRU cache for statement term values -> thread-local Jim objects.

// TODO: should we keep a hash alongside each term?

typedef struct Cache Cache;

Cache* cacheNew(Jim_Interp* interp);

void cacheInsert(Cache* cache, Jim_Interp* interp,
                 Jim_Obj* obj);
Jim_Obj* cacheGetOrInsert(Cache* cache, Jim_Interp* interp,
                          const char* term);

#endif
