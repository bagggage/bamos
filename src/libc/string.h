#pragma once

typedef unsigned long long size_t;

//memcpy();

//memset();

size_t strlen(const char* restrict string);

int strcmp(const char* restrict lhs, const char* restrict rhs);

char* strcpy(char* restrict dest, const char* restrict src);
char* strcat(char *restrict dest, const char *restrict src);

void memcpy(void* dst, const void* src, size_t size);
int memcmp(const void* restrict lhs, const void* restrict rhs, size_t size);

//strcpy();

//strcat();

//strchr();