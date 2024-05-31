#pragma once

#define SYS_READ    0
#define SYS_WRITE   1
#define SYS_OPEN    2
#define SYS_CLOSE   3
#define SYS_STAT    4

#define SYS_MMAP    9

#define SYS_MUNMAP  11

#define SYS_CLONE   56
#define SYS_FORK    57
#define SYS_VFORK   58
#define SYS_EXECVE  59

#define SYS_GETDENTS 78

#ifndef KERNEL

__attribute__((naked)) static long syscall(long number, ...) {
    asm volatile(
        "mov %%rdi,%%rax \n"
        "mov %%rsi,%%rdi \n"
        "mov %%rdx,%%rsi \n"
        "mov %%rcx,%%rdx \n"
        "mov %%r8,%%r10 \n"
        "mov %%r9,%%r8 \n"
        "mov 8(%%rsp),%%r9 \n"
        "syscall \n"
        "retq"
        :
        :
        :
        "%rax","%rcx","%r10","%r11"
    );
}

#endif