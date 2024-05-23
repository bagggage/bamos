#pragma once

#include <stdarg.h>

#define EOF

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEKK_END 2

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

typedef unsigned long long size_t;

typedef struct FILE {
    long _fileno;
} FILE;

extern FILE* stderr;

int fflush(FILE* restrict stream);

int vfprintf(FILE* restrict stream, const char* restrict fmt, va_list args);

static inline int fprintf(FILE* restrict stream, const char* restrict fmt, ...) {
    va_list args;

    va_start(args, fmt);
    int result = vfprintf(stream, fmt, args);
    va_end(args);

    return result;
}

int vsprintf(const char* buffer, const char* fmt, va_list args);

static inline int sprintf(const char* buffer, const char* fmt, ...) {
    va_list args;

    va_start(args, fmt);
    int result = vsprintf(buffer, fmt, args);
    va_end(args);

    return result;
}

size_t fread(void* restrict buffer, size_t size, size_t count, FILE* restrict stream);
size_t fwrite(const void* restrict buffer, size_t size, size_t count, FILE* restrict stream);

FILE* fopen(const char* restrict filename, const char* restrict mode);
int fclose(FILE* restrict stream);

int fseek(FILE* restrict stream, long offset, int whence);

void setbuf(FILE* restrict stream, char* restrict buffer);
