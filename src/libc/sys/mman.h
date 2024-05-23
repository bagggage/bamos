#pragma once

#define PROT_NONE   0
#define PROT_EXEC   01
#define PROT_READ   02
#define PROT_WRITE  04

#define MAP_FIXED       0
#define MAP_SHARED      01
#define MAP_PRIVATE     02
#define MAP_ANONYMOUS   04

#ifndef KERNEL

typedef unsigned long long size_t;
typedef unsigned long long off_t;

void* mmap(void* address, size_t length, int protection, int flags, int fd, off_t offset);
int munmap(void* address, size_t length);

#endif