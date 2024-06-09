#include "string.h"

#define UCHAR_MAX 255
#define ALIGN (sizeof(size_t))
#define ONES ((size_t)-1 / UCHAR_MAX)
#define HIGHS (ONES * (UCHAR_MAX / 2 + 1))
#define HASZERO(x) ((x)-ONES & ~(x) & HIGHS)

size_t strlen(const char *s) {
	const char *a = s;
	const size_t *w;

	for (; (unsigned long long)s % ALIGN; s++) if (!*s) return s-a;
	for (w = (const void *)s; !HASZERO(*w); w++);
	for (s = (const void *)w; *s; s++);

	return s - a;
}

int strcmp(const char* restrict lhs, const char* restrict rhs) {
    register char res;

    while (1) {
        if ((res = *lhs - *rhs++) != 0 || !*lhs++) break;
    }

    return res;
}

char* strcpy(char* restrict dest, const char* restrict src) {
	const unsigned char* s = src;
	unsigned char* d = dest;

	while ((*d++ = *s++));

	return dest;
}

char* strcat(char* restrict dest, const char* restrict src) {
    strcpy(dest + strlen(dest), src);
    return dest;
}

void memcpy(void* dst, const void* src, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        ((char*)dst)[i] = ((const char*)src)[i];
    }
}

int memcmp(const void* restrict lhs, const void* restrict rhs, size_t size) {
    const char* l = lhs;
    const char* r = rhs;

    for (; size && *l == *r; size--, l++, r++);

    return (size != 0 ? (*l - *r) : 0);
}