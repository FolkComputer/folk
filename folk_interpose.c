// folk_interpose.c -- macOS write() interposer.
//
// dyld only honors __DATA,__interpose sections from dylibs, not from the main
// executable. This file is built as folk_interpose.dylib and linked into folk
// so dyld processes the interpose at launch and redirects all write() calls
// (including from C libraries like printf/fprintf) through redirectWrite().
//
// redirectWrite() calls back into folk via folkGetFdOverride() to perform the
// per-thread fd substitution set up by __installLocalStdoutAndStderr.

#define _GNU_SOURCE
#include <unistd.h>
#include <sys/syscall.h>

// Defined in folk (main executable), exported to dylibs.
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
