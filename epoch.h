#ifndef EPOCH_H
#define EPOCH_H

#include <stdbool.h>

// Call this at startup from each thread that will use epoch-based
// reclamation.
void epochThreadInit();

void epochBegin();

// You should only do the below while in an epoch:

// Mark a pointer for potential retirement at the end of the epoch.
void epochMark(void *ptr);
// Undo all the markings so far in this epoch, if you're backtracking
// and don't actually want to free these pointers anymore.
void epochUnmarkAll();
// Retire all the marked points from this epoch.
void epochRetireAll();

void epochEnd();

void epochCollect();

#endif
