#pragma once

#define JIM_EMBEDDED
#include <jim.h>

extern int realStdout;
extern int realStderr;

void outputRedirectionInit(void);
void outputRedirectionInterpSetup(Jim_Interp *interp);
