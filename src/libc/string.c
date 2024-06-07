#include "string.h"

int strlen(const char* restrict string) {
    int result = 0;

    for (; *(string++) != '\0'; ++result);

    return result;
}

int strcmp(const char* restrict lhs, const char* restrict rhs) {
    register char res;

    while (1) {
        if ((res = *lhs - *rhs++) != 0 || !*lhs++) break;
    }

    return res;
}