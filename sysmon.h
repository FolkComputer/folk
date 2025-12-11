#ifndef SYSMON_H
#define SYSMON_H

void sysmonInit(int targetNotBlockedWorkersCount);
void *sysmonMain(void *ptr);

void sysmonScheduleRemoveAfter(StatementRef stmtRef, int afterMs);

#endif
