#ifndef BLOCK_STATS_H
#define BLOCK_STATS_H

#include <stdint.h>
#include <jim.h>

void blockStatsInit(void);
void blockStatsUpdate(const char *sourceFileName, int sourceLineNumber,
                      int64_t elapsed_ns);
int __blockRuntimeStatsFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv);

#endif
