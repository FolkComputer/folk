#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <assert.h>
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

typedef struct { void *replacer; void *replacee; } interpose_t;
static interpose_t write_interpose[] __attribute__((section("__DATA,__interpose"), used)) = {
    { (void *)redirectWrite, (void *)write }
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

#ifdef __APPLE__
    // Redirect fd 1/2 to /dev/null so system frameworks (NSLog, AppKit, etc.)
    // see a non-TTY and suppress their stderr output. All legitimate writes go
    // through folk_interpose.dylib -> folkGetFdOverride -> realStdout/realStderr.
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    dup2(devnull, STDERR_FILENO);
    close(devnull);
#endif
}

void installLocalStdoutAndStderr(int stdoutfd, int stderrfd) {
    threadLocalStdout = stdoutfd;
    threadLocalStderr = stderrfd;
}

static int __installLocalStdoutAndStderrFunc(Jim_Interp *interp, int argc, Jim_Obj *const *argv) {
    assert(argc == 3);
    int stdoutfd = Jim_AioFilehandle(interp, argv[1]);
    int stderrfd = Jim_AioFilehandle(interp, argv[2]);
    if (stdoutfd == -1 || stderrfd == -1) { return JIM_ERR; }
    installLocalStdoutAndStderr(stdoutfd, stderrfd);
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
