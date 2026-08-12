#pragma once

#include <stdbool.h>
#include <libzicl.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(bool doRedirect);
void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);
void outputRedirectionInterpSetup(Zicl_Interp *interp);
