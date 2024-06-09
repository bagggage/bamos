#include "stdlib.h"

#include "stdio.h"
#include "string.h"
#include "sys/mman.h"
#include "sys/syscall.h"

char** environ = NULL;
unsigned int errno = 0;

int abs(int x) {

}

void abort() {

}

int atexit(void (*function)(void)) {

}

int atoi(const char* restrict string) {

}

char* getenv(const char* restrict name) {
    if (environ == NULL) return NULL;

    const size_t env_name_length = strlen(name);
    char** env = environ;

    while (*env != NULL) {
        char* var = *env;

        if (memcmp(var, name, env_name_length) == 0) {
            var += env_name_length;

            if (*var != '=') return NULL;

            return var + 1;
        }

        env++;
    }

    return NULL;
}

__attribute__((noreturn)) void exit(int status) {
    _syscall_arg1(SYS_EXIT, status);
}