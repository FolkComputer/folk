#pragma once

#include <stdbool.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(bool doRedirect);
void installLocalStdoutAndStderr(int stdoutfd, int stderrfd);
