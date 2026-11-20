#ifndef SYSMON_H
#define SYSMON_H

void sysmonInit(int targetNotBlockedWorkersCount);
void *sysmonMain(void *ptr);

void sysmonScheduleRemoveAfter(StatementRef stmtRef, int afterMs,
                               uint64_t keepGeneration);

// Watchdog: bracket a call that might never return (e.g., a Vulkan
// present to a projector that was just powered off) with Enter/Leave.
// If the call is still running after the watchdog timeout, sysmon
// logs `what` and exits the process so that the service manager can
// restart Folk. `what` must be a string that outlives the call.
//
// Don't FOLK_ERROR (longjmp) out between Enter and Leave.
void folkWatchdogEnter(const char* what);
void folkWatchdogLeave(void);
// Log why and exit immediately, for failures that can't be recovered
// from inside the process (e.g., VK_ERROR_DEVICE_LOST).
void folkWatchdogDie(const char* format, ...);

#endif
