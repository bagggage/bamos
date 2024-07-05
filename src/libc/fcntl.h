#pragma once

#define O_RDONLY    00
#define O_WRONLY    01
#define O_RDWR      02
#define O_ACCMODE   03
#define O_CREAT     0100
#define O_EXCL      0200
#define O_NOCTTY    0400
#define O_TRUNC     01000
#define O_APPEND    02000
#define O_NONBLOCK  04000
#define O_DSYNC     010000
#define O_DIRECT    040000
#define O_LARGEFILE 0100000
#define O_DIRECTORY 0200000
#define O_NONFOLLOW 0400000
#define O_NOATIME   01000000
#define O_CLOEXEC   02000000

#define AT_FDCWD	-100

typedef unsigned int mode_t;

#ifndef KERNEL

#include "sys/syscall.h"

static inline int open(const char* pathname, int flags) {
    return _syscall_arg2(SYS_OPEN, (_arg_t)pathname, flags);
}

static inline int close(unsigned int fd) {
    return _syscall_arg1(SYS_CLOSE, fd);
}

static inline int openat(int dir_fd, const char* pathname, int flags, mode_t mode) {
    return _syscall_arg4(SYS_OPENAT, dir_fd, (_arg_t)pathname, flags, mode);
}

#endif