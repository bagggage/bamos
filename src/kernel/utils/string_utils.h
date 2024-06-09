#pragma once 

#include "definitions.h"

static inline bool_t is_ascii(const char c) {
    return (((c >= ' ') && (c <= '~')) || ((c == '\n') || (c == '\b'))) ? TRUE : FALSE;
}

static inline bool_t isalpha(char c) {
    return ((unsigned)c | 32) - 'a' < 26;
}

static inline bool_t isdigit(char c) {
	return (unsigned)c - '0' < 10;
}

static inline bool_t isalnum(char c) {
    return isalpha(c) || isdigit(c);
}

static inline bool_t isspace(char c) {
	return c == ' ' || (unsigned)c - '\t' < 5;
}

bool_t is_buffer_binary(const char* const buffer);