#pragma once

#undef NULL
#define NULL ((void*)0)

typedef unsigned long long size_t;

extern char** environ;

int abs(int x);

void abort();
int atexit(void (*function)(void));

int atoi(const char* restrict string);

void* malloc(size_t size);
void* calloc(size_t size, size_t count);
void free(void* restrict memory_block);

char* getenv(const char* restrict name);

void exit(int status) __attribute__((noreturn));