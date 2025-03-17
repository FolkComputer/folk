#ifndef SYSMON_H
#define SYSMON_H

void sysmonInit();
void *sysmonMain(void *ptr);

void sysmonScheduleRemoveAfter(StatementRef stmtRef, int afterMs);

#endif
