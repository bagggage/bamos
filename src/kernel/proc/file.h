#pragma once

#include "cpu/spinlock.h"
#include "fs/vfs.h"

typedef struct FileDescriptor {
    VfsDentry* dentry;
    int mode;
    uint64_t cursor_offset;
    Spinlock lock;
} FileDescriptor;

typedef struct Process Process;

long fd_open(Process* const process, const char* const filename, int flags);
bool_t fd_close(Process* const process, const uint32_t descriptor);
