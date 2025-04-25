#include <string.h>
#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include "cache.h"

// Based on this algorithm: https://github.com/dominictarr/hashlru

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
static void *cacheHTKeyDup(void *privdata, const void *key) {
    return strdup(key);
}
static void *cacheHTValDup(void *privdata, const void *val) {
    Jim_IncrRefCount((Jim_Obj *)val);
    return val;
}
static int cacheHTKeyCompare(void *privdata, const void *key1, const void *key2) {
    return strcmp(key1, key2) == 0;
}
static void cacheHTKeyDestructor(void *privdata, void *key) {
    free(key);
}
static void cacheHTValDestructor(void *privdata, void *val) {
    Jim_DecrRefCount((Jim_Interp *)privdata, (Jim_Obj *)val);
}

static const Jim_HashTableType cacheHashTableType = {
    .hashFunction = cacheHTHashFunction,
    .keyDup = cacheHTKeyDup,
    .valDup = cacheHTValDup,
    .keyCompare = cacheHTKeyCompare,
    .keyDestructor = cacheHTKeyDestructor,
    .valDestructor = cacheHTValDestructor
};

typedef struct Cache {
    Jim_HashTable oldTable;
    Jim_HashTable newTable;
    int size;
} Cache;

Cache* cacheNew(Jim_Interp* interp) {
    Cache* cache = malloc(sizeof(Cache));
    Jim_InitHashTable(&cache->oldTable, &cacheHashTableType, interp);
    Jim_InitHashTable(&cache->newTable, &cacheHashTableType, interp);
    return cache;
}

#define CACHE_MAX 2048
static void cacheTryEvict(Cache* cache, Jim_Interp* interp) {
    if (cache->size > CACHE_MAX) {
        Jim_FreeHashTable(&cache->oldTable);
        memcpy(&cache->oldTable, &cache->newTable, sizeof(Jim_HashTable));
        cache->size = 0;
        Jim_InitHashTable(&cache->newTable, &cacheHashTableType, interp);
    }
}

void cacheInsert(Cache* cache, Jim_Interp* interp,
                 Jim_Obj* obj) {
    /* const char* term = Jim_GetString(obj, NULL); */

    /* Jim_HashEntry* ent = Jim_FindHashEntry(&cache->newTable, term); */
    /* if (ent != NULL) { return; } */

    /* ent = Jim_FindHashEntry(&cache->oldTable, term); */
    /* if (ent != NULL) { */
    /*     // Bump the entry to the new table, since it's now */
    /*     // recently-used. */
    /*     Jim_Obj* obj = Jim_GetHashEntryVal(ent); */
    /*     Jim_AddHashEntry(&cache->newTable, term, obj); */
    /*     Jim_DeleteHashEntry(&cache->oldTable, term); */
    /*     cache->size++; */
    /*     cacheTryEvict(cache, interp); */
    /*     return; */
    /* } */

    /* // Not in cache yet. Insert into cache. */
    /* Jim_AddHashEntry(&cache->newTable, term, obj); */
    /* cache->size++; */
    /* cacheTryEvict(cache, interp); */
}

Jim_Obj* cacheGetOrInsert(Cache* cache, Jim_Interp* interp,
                          const char* term) {
    Jim_Obj* obj = Jim_NewStringObj(interp, term, -1);
    return obj;

    /* Jim_HashEntry* ent = Jim_FindHashEntry(&cache->newTable, term); */
    /* if (ent != NULL) { */
    /*     return Jim_GetHashEntryVal(ent); */
    /* } */

    /* ent = Jim_FindHashEntry(&cache->oldTable, term); */
    /* if (ent != NULL) { */
    /*     // Bump the entry to the new table, since it's now */
    /*     // recently-used. */
    /*     Jim_Obj* obj = Jim_GetHashEntryVal(ent); */
    /*     Jim_AddHashEntry(&cache->newTable, term, obj); */
    /*     Jim_DeleteHashEntry(&cache->oldTable, term); */
    /*     cache->size++; */
    /*     cacheTryEvict(cache, interp); */
    /*     return obj; */
    /* } */

    /* // Not in cache yet. Insert into cache. */
    /* Jim_Obj* obj = Jim_NewStringObj(interp, term, -1); */
    /* Jim_AddHashEntry(&cache->newTable, term, obj); */
    /* cache->size++; */
    /* cacheTryEvict(cache, interp); */

    /* return obj; */
}
