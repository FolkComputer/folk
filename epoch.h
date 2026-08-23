#ifndef EPOCH_H
#define EPOCH_H

#include <stdbool.h>

struct Zicl_Object;

// Call this at startup from each thread that will use epoch-based
// reclamation.
void epochThreadInit();
void epochThreadDestroy();

void epochBegin();

// You can call this whenever, as long as it's always from the same
// thread.
void epochGlobalCollect();

// You should only do the below while in an epoch:

// Reversible operations:
// Allocate from the heap.
void *epochAlloc(size_t sz);
// 'Pseudo-free' a pointer (mark it for potential retirement at the
// end of the epoch).
void epochFree(void *ptr);
// Defer Zicl_DropRef on a Zicl_Object until after all concurrent
// epoch-protected readers have finished. Use this instead of
// Zicl_DropRef when retiring trie nodes whose keys must outlive
// the epoch-protected window.
void epochDecrRef(struct Zicl_Object* value);

// Undo all allocations and frees on this thread since it called
// epochBegin. You're still in the epoch when this returns.
void epochReset();

// Also commits all allocations and frees (pointer retirements) from
// the current epoch.
void epochEnd();

#endif
