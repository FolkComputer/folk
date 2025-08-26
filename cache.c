#include <string.h>
#if __has_include ("tracy/TracyC.h")
#include "tracy/TracyC.h"
#endif

#include "cache.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>

typedef struct CacheNode {
    const char *key;
    Jim_Obj *obj;
    struct CacheNode *prev;
    struct CacheNode *next;
} CacheNode;

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

static int cacheHTKeyCompare(void *privdata, const void *key1, const void *key2) {
    return strcmp(key1, key2) == 0;
}

static const Jim_HashTableType cacheHashTableType = {
    .hashFunction = cacheHTHashFunction,
    .keyDup = NULL,
    .valDup = NULL,
    .keyCompare = cacheHTKeyCompare,
    .keyDestructor = NULL,
    .valDestructor = NULL
};

typedef struct Cache {
    Jim_HashTable table;
    int size;

    CacheNode *head;
    CacheNode *tail;
} Cache;

Cache* cacheNew(Jim_Interp* interp) {
    Cache* cache = malloc(sizeof(Cache));
    Jim_InitHashTable(&cache->table, &cacheHashTableType, interp);
    cache->head = NULL;
    cache->tail = NULL;
    return cache;
}

#define CACHE_MAX 2048

static void cacheMoveToHeadHelper(Cache* cache, CacheNode* node);
static CacheNode* cacheInsertHelper(Cache* cache, Jim_Interp* interp,
                                    Jim_Obj* obj) {
    CacheNode* node = malloc(sizeof(CacheNode));
    char* key = strdup(Jim_GetString(obj, NULL));
    Jim_AddHashEntry(&cache->table, key, node);
    cache->size++;

    node->prev = NULL;
    node->next = NULL;
    node->obj = obj;
    node->key = key;
    Jim_IncrRefCount(node->obj);

    cacheMoveToHeadHelper(cache, node);

    // If cache size exceeds max, evict oldest entry
    if (cache->size >= CACHE_MAX) {
        if (cache->tail && cache->tail != node) {
            CacheNode* oldest = cache->tail;
            
            // Remove from hash table
            Jim_DeleteHashEntry(&cache->table, oldest->key);
            
            // Unlink from list
            if (oldest->prev) {
                oldest->prev->next = NULL;
            }
            cache->tail = oldest->prev;
            
            // Clean up the node
            Jim_DecrRefCount(interp, oldest->obj);
            free((char*)oldest->key);
            free(oldest);
            
            cache->size--;
        }
    }

    return node;
}
static void cacheMoveToHeadHelper(Cache* cache, CacheNode* node) {
    // Move/add node to head of list
    if (node != cache->head) {
        // Remove node from current position if it exists in list
        if (node->prev) {
            node->prev->next = node->next;
        }
        if (node->next) {
            node->next->prev = node->prev;
        }
        
        // If it was the tail, update tail
        if (node == cache->tail) {
            cache->tail = node->prev;
        }

        // Add to head
        node->prev = NULL;
        node->next = cache->head;
        if (cache->head) {
            cache->head->prev = node;
        }
        cache->head = node;

        // If no tail yet, set it
        if (!cache->tail) {
            cache->tail = node;
        }
    }
}

void cacheInsert(Cache* cache, Jim_Interp* interp,
                 Jim_Obj* obj) {
    int len;
    const char* term = Jim_GetString(obj, &len);
    if (len < 15) { return; }

    Jim_HashEntry* ent = Jim_FindHashEntry(&cache->table, term);
    if (ent != NULL) { return; }

    cacheInsertHelper(cache, interp, obj);
}

Jim_Obj* cacheGetOrInsert(Cache* cache, Jim_Interp* interp,
                          const char* term) {
    int len = strlen(term);
    if (len < 15) { return Jim_NewStringObj(interp, term, len); }

    Jim_HashEntry* ent = Jim_FindHashEntry(&cache->table, term);
    CacheNode* node;
    if (ent != NULL) {
        node = Jim_GetHashEntryVal(ent);
        cacheMoveToHeadHelper(cache, node);
    } else {
        // Not in cache yet. Insert into cache.
        Jim_Obj* obj = Jim_NewStringObj(interp, term, len);
        node = cacheInsertHelper(cache, interp, obj);
    }

    return node->obj;
}
