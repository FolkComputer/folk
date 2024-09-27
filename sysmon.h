#ifndef SYSMON_H
#define SYSMON_H

void sysmonInit();
void *sysmonMain(void *ptr);
void sysmonRemoveLater(StatementRef stmtRef, int laterMs);

#endif
