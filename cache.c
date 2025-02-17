#include <string.h>
#include "cache.h"

/* Generic string hash function from jim.c */
static unsigned int cacheGenHashFunction(const unsigned char *string, int length) {
    unsigned result = 0;
    string += length;
    while (length--) {
        result += (result << 3) + (unsigned char)(*--string);
    }
    return result;
}
static unsigned int cacheHTHashFunction(const void *key) {
    return cacheGenHashFunction(key, strlen(key));
}
static void *cacheHTDup(void *privdata, const void *key) {
    return strdup(key);
}
static int cacheHTKeyCompare(void *privdata, const void *key1, const void *key2) {
    return strcmp(key1, key2) == 0;
}
static void cacheHTKeyDestructor(void *privdata, void *key) {
    free(key);
}
static void cacheHTValDestructor(void *privdata, void *key) {
    //    Jim_DecrRefCount(interp, );
}

static const Jim_HashTableType cacheHashTableType = {
    .hashFunction = cacheHTHashFunction,
    .keyDup = cacheHTDup,
    .valDup = NULL,
    .keyCompare = cacheHTKeyCompare,
    .keyDestructor = cacheHTKeyDestructor,
    .valDestructor = NULL
};

Cache* cacheNew() {
    Cache* cache = malloc(sizeof(Cache));
    Jim_InitHashTable(cache, &cacheHashTableType, NULL);
    return cache;
}

#define CACHE_MAX 256
Jim_Obj* cacheGetOrInsert(Cache* cache, Jim_Interp* interp,
                          const char* term) {
    Jim_HashEntry* ent = Jim_FindHashEntry(cache, term);
    if (ent != NULL) {
        // TODO: do LRU reordering
        return Jim_GetHashEntryVal(ent);
    }

    Jim_Obj* obj = Jim_NewStringObj(interp, term, -1);
    Jim_AddHashEntry(cache, term, obj);
    Jim_IncrRefCount(obj);

    // TODO: check and evict
    if (Jim_GetHashTableUsed(cache) > CACHE_MAX) {
        
    }

    return obj;
}
