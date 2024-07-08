#pragma once

#define EOF (-1)

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEKK_END 2

#ifndef KERNEL

#include <stdarg.h>

typedef unsigned long long size_t;

typedef struct FILE {
    long _fileno;
} FILE;

extern FILE* stdin;
extern FILE* stdout;
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

static inline int printf(const char* restrict fmt, ...) {
    va_list args;

    va_start(args, fmt);
    int result = vfprintf(stdout, fmt, args);
    va_end(args);

    return result;
}

int vsprintf(char* buffer, const char* fmt, va_list args);

static inline int sprintf(char* buffer, const char* fmt, ...) {
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

int fputc(int c, FILE* restrict stream);
int fputs(const char* string, FILE* restrict stream);

static inline int putc(int c, FILE* restrict stream) {
    return fputc(c, stream);
}

static inline int putchar(int c) {
    return fputc(c, stdout);
}

static inline int puts(const char* string) {
    return fputs(string, stdout);
}

int fgetc(FILE* restrict stream);
char* fgets(char* buffer, int size, FILE* restrict stream);

static inline int getc(FILE* restrict stream) {
    return fgetc(stream);
}

static inline int getchar() {
    return fgetc(stdin);
}

char* gets(char* buffer);

#endif