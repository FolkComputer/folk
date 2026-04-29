#ifndef BLOCK_STATS_H
#define BLOCK_STATS_H

#include <stdint.h>
#include <libzicl.h>

void blockStatsInit(void);
void blockStatsUpdate(const char *sourceFileName, int sourceLineNumber,
                      int64_t elapsed_ns);
int __blockRuntimeStatsFunc(Zicl_Interp *interp, int argc, Zicl_Handle *const argv);

#endif
