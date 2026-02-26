#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <assert.h>
#include <pthread.h>
#include <sys/syscall.h>

#ifdef FOLK_INTERPOSE_DYLIB
// macOS dylib build: just the __DATA,__interpose section that redirects
// write() calls. folkGetFdOverride() is defined in the main binary and
// resolved at runtime via dynamic_lookup.
extern int folkGetFdOverride(int fd);

static ssize_t redirectWrite(int fd, const void *buf, size_t count) {
    fd = folkGetFdOverride(fd);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return (ssize_t)syscall(SYS_write, fd, buf, count);
#pragma clang diagnostic pop
}

static int replacePrintf(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (n > 0) redirectWrite(STDOUT_FILENO, buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
    return n;
}

static int replaceFprintf(FILE *stream, const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (n > 0) redirectWrite(fileno(stream), buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
    return n;
}

static int replacePuts(const char *s) {
    size_t len = strlen(s);
    char buf[4096];
    if (len + 1 < sizeof(buf)) {
        memcpy(buf, s, len);
        buf[len] = '\n';
        redirectWrite(STDOUT_FILENO, buf, len + 1);
    }
    return 1;
}

static size_t replaceFwrite(const void *buf, size_t size, size_t count, FILE *stream) {
    redirectWrite(fileno(stream), buf, size * count);
    return count;
}

typedef struct { void *replacer; void *replacee; } interpose_t;
static interpose_t write_interpose[] __attribute__((section("__DATA,__interpose"), used)) = {
    { (void *)redirectWrite,  (void *)write   },
    { (void *)replacePrintf,  (void *)printf  },
    { (void *)replaceFprintf, (void *)fprintf },
    { (void *)replacePuts,    (void *)puts    },
    { (void *)replaceFwrite,  (void *)fwrite  },
};

#else
// Normal build (linked into main binary): output redirection globals,
// per-thread fd substitution, and Jim command registration.

#include <jim.h>

int realStdout = -1;
int realStderr = -1;

// Per-thread stdout/stderr fds, set when a when-body redirects its output.
__thread int threadLocalStdout = -1;
__thread int threadLocalStderr = -1;

#ifdef __APPLE__
// Called by the __DATA,__interpose section in folk_interpose.dylib
// (compiled from this same file with -DFOLK_INTERPOSE_DYLIB) for every
// write()/printf()/etc. call. fd 1/2 are redirected to /dev/null in
// outputRedirectionInit() so that NSLog and other system frameworks see a
// non-TTY and suppress their stderr output. All legitimate writes go back
// to the saved realStdout/realStderr (or the per-thread per-program file
// when inside a when-body).
int folkGetFdOverride(int fd) {
    if (fd == STDOUT_FILENO) {
        return threadLocalStdout != -1 ? threadLocalStdout : realStdout;
    }
    if (fd == STDERR_FILENO) {
        return threadLocalStderr != -1 ? threadLocalStderr : realStderr;
    }
    return fd;
}
#else
// On Linux, override write() as a strong symbol that takes priority over
// libc's weak symbol.
ssize_t write(int fd, const void *buf, size_t count) {
    if (fd == STDOUT_FILENO && threadLocalStdout != -1) fd = threadLocalStdout;
    else if (fd == STDERR_FILENO && threadLocalStderr != -1) fd = threadLocalStderr;
    return (ssize_t)syscall(SYS_write, fd, buf, count);
}
#endif

// Override printf/fprintf/puts/fwrite in the main binary so that
// JIT-compiled .so files loaded via dlopen find our versions first
// (via flat-namespace / RTLD_DEFAULT lookup) and their output is
// properly redirected through write().
//
// On Linux this also bypasses glibc's hidden __libc_write that
// stdio uses internally and would otherwise escape our write() override.
int printf(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (n > 0) write(STDOUT_FILENO, buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
    return n;
}

int fprintf(FILE *stream, const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    if (n > 0) write(fileno(stream), buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
    return n;
}

size_t fwrite(const void *buf, size_t size, size_t count, FILE *stream) {
    write(fileno(stream), buf, size * count);
    return count;
}

void outputRedirectionInit(void) {
    // Save stdout and stderr once, globally.
    realStdout = dup(1);
    realStderr = dup(2);

    // Redirect fd 1/2 to /dev/null so system frameworks (NSLog,
    // AppKit, etc.)  see a non-TTY and suppress their stderr
    // output. All legitimate writes go through folk_interpose.dylib
    // -> folkGetFdOverride, or to realStdout/realStderr.
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    dup2(devnull, STDERR_FILENO);
    close(devnull);
}

void installLocalStdoutAndStderr(int stdoutfd, int stderrfd) {
    threadLocalStdout = stdoutfd;
    threadLocalStderr = stderrfd;
}

#define PROGRAM_FDS_MAX 1024
typedef struct { char *name; int stdoutfd; int stderrfd; } ProgramFds;
static pthread_mutex_t programFdsMutex = PTHREAD_MUTEX_INITIALIZER;
static ProgramFds programFdsTable[PROGRAM_FDS_MAX];
static int programFdsCount = 0;

static void escapeProgramName(const char *in, char *out, size_t outlen) {
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0'; i++) {
        if (in[i] == '/') {
            if (j + 2 < outlen - 1) { out[j++] = '_'; out[j++] = '_'; }
        } else {
            if (j < outlen - 1) out[j++] = in[i];
        }
    }
    out[j] = '\0';
}

static int __installLocalStdoutAndStderrFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 2);
    const char *this = Jim_String(argv[1]);

    pthread_mutex_lock(&programFdsMutex);
    int stdoutfd = -1, stderrfd = -1;
    for (int i = 0; i < programFdsCount; i++) {
        if (strcmp(programFdsTable[i].name, this) == 0) {
            stdoutfd = programFdsTable[i].stdoutfd;
            stderrfd = programFdsTable[i].stderrfd;
            break;
        }
    }
    if (stdoutfd == -1 && programFdsCount < PROGRAM_FDS_MAX) {
        char escaped[2048];
        escapeProgramName(this, escaped, sizeof(escaped));
        char path[4096];
        snprintf(path, sizeof(path), "/tmp/%d.%s.stdout", (int)getpid(), escaped);
        stdoutfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        snprintf(path, sizeof(path), "/tmp/%d.%s.stderr", (int)getpid(), escaped);
        stderrfd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        programFdsTable[programFdsCount].name = strdup(this);
        programFdsTable[programFdsCount].stdoutfd = stdoutfd;
        programFdsTable[programFdsCount].stderrfd = stderrfd;
        programFdsCount++;
    }
    pthread_mutex_unlock(&programFdsMutex);

    if (stdoutfd == -1 || stderrfd == -1) { return JIM_ERR; }
    installLocalStdoutAndStderr(stdoutfd, stderrfd);

    // Set ::_folk_localStdout/Stderr as non-owning channels for the exec wrapper.
    Jim_AioMakeChannelFromFd(interp, stdoutfd, 0);
    Jim_SetVariableStr(interp, "::_folk_localStdout", Jim_GetResult(interp));
    Jim_AioMakeChannelFromFd(interp, stderrfd, 0);
    Jim_SetVariableStr(interp, "::_folk_localStderr", Jim_GetResult(interp));

    return JIM_OK;
}

void outputRedirectionInterpSetup(Jim_Interp *interp) {
    assert(realStdout != -1 && realStderr != -1);
    Jim_AioMakeChannelFromFd(interp, realStdout, 1);
    Jim_SetVariableStr(interp, "::realStdout", Jim_GetResult(interp));
    Jim_AioMakeChannelFromFd(interp, realStderr, 1);
    Jim_SetVariableStr(interp, "::realStderr", Jim_GetResult(interp));

    Jim_CreateCommand(interp, "__installLocalStdoutAndStderr",
                      __installLocalStdoutAndStderrFunc, NULL, NULL);
}

#endif // FOLK_INTERPOSE_DYLIB
