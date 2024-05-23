#include "mman.h"

#include "syscall.h"

void* mmap(void* address, size_t length, int protection, int flags, int fd, off_t offset) {
    return (void*)syscall(SYS_MMAP, address, length, protection, flags, fd, offset);
}

int munmap(void* address, size_t length) {
    return (int)syscall(SYS_MUNMAP, address, length);
}