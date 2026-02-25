#pragma once

#define JIM_EMBEDDED
#include <jim.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(void);
void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);
void outputRedirectionInterpSetup(Jim_Interp *interp);
