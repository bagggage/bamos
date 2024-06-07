#include "stdlib.h"

#include "sys/mman.h"
#include "sys/syscall.h"

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

}

__attribute__((noreturn)) void exit(int status) {
    _syscall_arg1(SYS_EXIT, status);
}