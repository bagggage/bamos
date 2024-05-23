#pragma once

typedef unsigned long long size_t;
typedef unsigned long long off_t;

void* mmap(void* address, size_t length, int protection, int flags, int fd, off_t offset);
int munmap(void* address, size_t length);