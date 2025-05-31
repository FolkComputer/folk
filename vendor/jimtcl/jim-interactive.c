#include <errno.h>
#include <string.h>
#include <stdio.h>

#include "jimautoconf.h"
#include <jim.h>

#ifdef USE_LINENOISE
#ifdef HAVE_UNISTD_H
    #include <unistd.h>
#endif
#ifdef HAVE_SYS_STAT_H
    #include <sys/stat.h>
#endif
#include "linenoise.h"
#else
#define MAX_LINE_LEN 512
#endif

#ifdef USE_LINENOISE
struct JimCompletionInfo {
    Jim_Interp *interp;
    Jim_Obj *completion_command;
    Jim_Obj *hints_command;
    /*Jim_Obj *hint;*/
};

static struct JimCompletionInfo *JimGetCompletionInfo(Jim_Interp *interp);
static void JimCompletionCallback(const char *prefix, linenoiseCompletions *comp, void *userdata);
static const char completion_callback_assoc_key[] = "interactive-completion";
static char *JimHintsCallback(const char *prefix, int *color, int *bold, void *userdata);
static void JimFreeHintsCallback(void *hint, void *userdata);
#endif

/**
 * Returns an allocated line, or NULL if EOF.
 */
char *Jim_HistoryGetline(Jim_Interp *interp, const char *prompt)
{
#ifdef USE_LINENOISE
    struct JimCompletionInfo *compinfo = JimGetCompletionInfo(interp);
    char *result;
    Jim_Obj *objPtr;
    long mlmode = 0;
    /* Set any completion callback just during the call to linenoise()
     * to allow for per-interp settings
     */
    if (compinfo->completion_command) {
        linenoiseSetCompletionCallback(JimCompletionCallback, compinfo);
    }
    if (compinfo->hints_command) {
        linenoiseSetHintsCallback(JimHintsCallback, compinfo);
        linenoiseSetFreeHintsCallback(JimFreeHintsCallback);
    }
    objPtr = Jim_GetVariableStr(interp, "history::multiline", JIM_NONE);
    if (objPtr && Jim_GetLong(interp, objPtr, &mlmode) == JIM_NONE) {
        linenoiseSetMultiLine(mlmode);
    }

    result = linenoise(prompt);
    /* unset the callbacks */
    linenoiseSetCompletionCallback(NULL, NULL);
    linenoiseSetHintsCallback(NULL, NULL);
    linenoiseSetFreeHintsCallback(NULL);
    return result;
#else
    int len;
    char *line = Jim_Alloc(MAX_LINE_LEN);

    fputs(prompt, stdout);
    fflush(stdout);

    if (fgets(line, MAX_LINE_LEN, stdin) == NULL) {
        Jim_Free(line);
        return NULL;
    }
    len = strlen(line);
    if (len && line[len - 1] == '\n') {
        line[len - 1] = '\0';
    }
    return line;
#endif
}

void Jim_HistoryLoad(const char *filename)
{
#ifdef USE_LINENOISE
    linenoiseHistoryLoad(filename);
#endif
}

void Jim_HistoryAdd(const char *line)
{
#ifdef USE_LINENOISE
    linenoiseHistoryAdd(line);
#endif
}

void Jim_HistorySave(const char *filename)
{
#ifdef USE_LINENOISE
#ifdef HAVE_UMASK
    mode_t mask;
    /* Just u=rw, but note that this is only effective for newly created files */
    mask = umask(S_IXUSR | S_IRWXG | S_IRWXO);
#endif
    linenoiseHistorySave(filename);
#ifdef HAVE_UMASK
    umask(mask);
#endif
#endif
}

void Jim_HistoryShow(void)
{
#ifdef USE_LINENOISE
    /* built-in history command */
    int i;
    int len;
    char **history = linenoiseHistory(&len);
    for (i = 0; i < len; i++) {
        printf("%4d %s\n", i + 1, history[i]);
    }
#endif
}

void Jim_HistorySetMaxLen(int length)
{
#ifdef USE_LINENOISE
    linenoiseHistorySetMaxLen(length);
#endif
}

int Jim_HistoryGetMaxLen(void)
{
#ifdef USE_LINENOISE
    return linenoiseHistoryGetMaxLen();
#endif
    return 0;
}

#ifdef USE_LINENOISE
static void JimCompletionCallback(const char *prefix, linenoiseCompletions *comp, void *userdata)
{
    struct JimCompletionInfo *info = (struct JimCompletionInfo *)userdata;
    Jim_Obj *objv[2];
    int ret;

    objv[0] = info->completion_command;
    objv[1] = Jim_NewStringObj(info->interp, prefix, -1);

    ret = Jim_EvalObjVector(info->interp, 2, objv);

    /* XXX: Consider how best to handle errors here. bgerror? */
    if (ret == JIM_OK) {
        int i;
        Jim_Obj *listObj = Jim_GetResult(info->interp);
        int len = Jim_ListLength(info->interp, listObj);
        for (i = 0; i < len; i++) {
            linenoiseAddCompletion(comp, Jim_String(Jim_ListGetIndex(info->interp, listObj, i)));
        }
    }
}

static char *JimHintsCallback(const char *prefix, int *color, int *bold, void *userdata)
{
    struct JimCompletionInfo *info = (struct JimCompletionInfo *)userdata;
    Jim_Obj *objv[2];
    int ret;
    char *result = NULL;

    objv[0] = info->hints_command;
    objv[1] = Jim_NewStringObj(info->interp, prefix, -1);

    ret = Jim_EvalObjVector(info->interp, 2, objv);

    /* XXX: Consider how best to handle errors here. bgerror? */
    if (ret == JIM_OK) {
        Jim_Obj *listObj = Jim_GetResult(info->interp);
        Jim_IncrRefCount(listObj);
        /* Should return a list of {hintstring color bold} where the second two are optional */
        int len = Jim_ListLength(info->interp, listObj);
        if (len >= 1) {
            long x;
            result = Jim_StrDup(Jim_String(Jim_ListGetIndex(info->interp, listObj, 0)));
            if (len >= 2 && Jim_GetLong(info->interp, Jim_ListGetIndex(info->interp, listObj, 1), &x) == JIM_OK) {
                *color = x;
            }
            if (len >= 3 && Jim_GetLong(info->interp, Jim_ListGetIndex(info->interp, listObj, 2), &x) == JIM_OK) {
                *bold = x;
            }
        }
        Jim_DecrRefCount(info->interp, listObj);
    }
    return result;
}

static void JimFreeHintsCallback(void *hint, void *userdata)
{
    Jim_Free(hint);
}

static void JimHistoryFreeCompletion(Jim_Interp *interp, void *data)
{
    struct JimCompletionInfo *compinfo = data;

    if (compinfo->completion_command) {
        Jim_DecrRefCount(interp, compinfo->completion_command);
    }
    if (compinfo->hints_command) {
        Jim_DecrRefCount(interp, compinfo->hints_command);
    }

    Jim_Free(compinfo);
}

static struct JimCompletionInfo *JimGetCompletionInfo(Jim_Interp *interp)
{
    struct JimCompletionInfo *compinfo = Jim_GetAssocData(interp, completion_callback_assoc_key);
    if (compinfo == NULL) {
        compinfo = Jim_Alloc(sizeof(*compinfo));
        compinfo->interp = interp;
        compinfo->completion_command = NULL;
        compinfo->hints_command = NULL;
        Jim_SetAssocData(interp, completion_callback_assoc_key, JimHistoryFreeCompletion, compinfo);
    }
    return compinfo;
}
#endif

/**
 * Sets a completion command to be used with Jim_HistoryGetline()
 * If commandObj is NULL, deletes any existing completion command.
 */
void Jim_HistorySetCompletion(Jim_Interp *interp, Jim_Obj *completionCommandObj)
{
#ifdef USE_LINENOISE
    struct JimCompletionInfo *compinfo = JimGetCompletionInfo(interp);

    if (completionCommandObj) {
        /* Increment now in case the existing object is the same */
        Jim_IncrRefCount(completionCommandObj);
    }
    if (compinfo->completion_command) {
        Jim_DecrRefCount(interp, compinfo->completion_command);
    }
    compinfo->completion_command = completionCommandObj;
#endif
}

/**
 * Sets a hints command to be used with Jim_HistoryGetline()
 * If commandObj is NULL, deletes any existing hints command.
 */
void Jim_HistorySetHints(Jim_Interp *interp, Jim_Obj *hintsCommandObj)
{
#ifdef USE_LINENOISE
    struct JimCompletionInfo *compinfo = JimGetCompletionInfo(interp);

    if (hintsCommandObj) {
        /* Increment now in case the existing object is the same */
        Jim_IncrRefCount(hintsCommandObj);
    }
    if (compinfo->hints_command) {
        Jim_DecrRefCount(interp, compinfo->hints_command);
    }
    compinfo->hints_command = hintsCommandObj;
#endif
}

int Jim_InteractivePrompt(Jim_Interp *interp)
{
    int retcode = JIM_OK;
    char *history_file = NULL;
#ifdef USE_LINENOISE
    const char *home;

    home = getenv("HOME");
    if (home && isatty(STDIN_FILENO)) {
        int history_len = strlen(home) + sizeof("/.jim_history");
        history_file = Jim_Alloc(history_len);
        snprintf(history_file, history_len, "%s/.jim_history", home);
        Jim_HistoryLoad(history_file);
    }

    Jim_HistorySetCompletion(interp, Jim_NewStringObj(interp, "tcl::autocomplete", -1));
    Jim_HistorySetHints(interp, Jim_NewStringObj(interp, "tcl::stdhint", -1));
#endif

    printf("Welcome to Jim version %d.%d\n",
        JIM_VERSION / 100, JIM_VERSION % 100);
    Jim_SetVariableStrWithStr(interp, JIM_INTERACTIVE, "1");

    while (1) {
        Jim_Obj *scriptObjPtr;
        const char *result;
        int reslen;
        char prompt[20];

        if (retcode != JIM_OK) {
            const char *retcodestr = Jim_ReturnCode(retcode);

            if (*retcodestr == '?') {
                snprintf(prompt, sizeof(prompt) - 3, "[%d] . ", retcode);
            }
            else {
                snprintf(prompt, sizeof(prompt) - 3, "[%s] . ", retcodestr);
            }
        }
        else {
            strcpy(prompt, ". ");
        }

        scriptObjPtr = Jim_NewStringObj(interp, "", 0);
        Jim_IncrRefCount(scriptObjPtr);
        while (1) {
            char state;
            char *line;

            line = Jim_HistoryGetline(interp, prompt);
            if (line == NULL) {
                if (errno == EINTR) {
                    continue;
                }
                Jim_DecrRefCount(interp, scriptObjPtr);
                retcode = JIM_OK;
                goto out;
            }
            if (Jim_Length(scriptObjPtr) != 0) {
                /* Line continuation */
                Jim_AppendString(interp, scriptObjPtr, "\n", 1);
            }
            Jim_AppendString(interp, scriptObjPtr, line, -1);
            Jim_Free(line);
            if (Jim_ScriptIsComplete(interp, scriptObjPtr, &state))
                break;

            snprintf(prompt, sizeof(prompt), "%c> ", state);
        }
#ifdef USE_LINENOISE
        if (strcmp(Jim_String(scriptObjPtr), "h") == 0) {
            /* built-in history command */
            Jim_HistoryShow();
            Jim_DecrRefCount(interp, scriptObjPtr);
            continue;
        }

        Jim_HistoryAdd(Jim_String(scriptObjPtr));
        if (history_file) {
            Jim_HistorySave(history_file);
        }
#endif
        retcode = Jim_EvalObj(interp, scriptObjPtr);
        Jim_DecrRefCount(interp, scriptObjPtr);

        if (retcode == JIM_EXIT) {
            break;
        }
        if (retcode == JIM_ERR) {
            Jim_MakeErrorMessage(interp);
        }
        result = Jim_GetString(Jim_GetResult(interp), &reslen);
        if (reslen) {
            if (fwrite(result, reslen, 1, stdout) == 0) {
                /* nothing */
            }
            putchar('\n');
        }
    }
  out:
    Jim_Free(history_file);

    return retcode;
}
