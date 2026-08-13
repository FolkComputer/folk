#pragma once

#include <stdbool.h>
#include <libzicl.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(bool doRedirect);
void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);
// Finds or creates `this`'s per-program stdout/stderr files and installs
// them as the calling thread's local stdout/stderr. A no-op if per-program
// redirection isn't set up (see outputRedirectionInit).
void installLocalStdoutAndStderrForProgram(const char *thisProgram);
void outputRedirectionInterpSetup(Zicl_Interp *interp);
