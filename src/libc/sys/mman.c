#include "mman.h"

#include "syscall.h"

void* mmap(void* address, size_t length, int protection, int flags, int fd, off_t offset) {
    long long result = _syscall_arg6(SYS_MMAP, (size_t)address, length, protection, flags, fd, offset);

    if (result < 0) return (void*)0;

    return (void*)result;
}

int munmap(void* address, size_t length) {
    return (int)_syscall_arg2(SYS_MUNMAP, (size_t)address, length);
}