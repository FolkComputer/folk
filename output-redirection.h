#pragma once

#define JIM_EMBEDDED
#include <jim.h>

#include <stdbool.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(bool doRedirect);
void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);
void outputRedirectionInterpSetup(Jim_Interp *interp);
