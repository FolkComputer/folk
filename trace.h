#ifndef TRACE_H
#define TRACE_H

// First 10,000 are head on boot.
#define TRACE_ENTRY_SIZE 1000
#define TRACE_HEAD_COUNT 10000

// This rotates so we can continuously fill it with latest entries.
#define TRACE_TAIL_COUNT 20000

extern char traceHead[TRACE_HEAD_COUNT][TRACE_ENTRY_SIZE];
extern char traceTail[TRACE_TAIL_COUNT][TRACE_ENTRY_SIZE];
extern int _Atomic traceNextIdx;

#endif
