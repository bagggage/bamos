#pragma once

#define SYS_READ    0
#define SYS_WRITE   1
#define SYS_OPEN    2
#define SYS_CLOSE   3
#define SYS_STAT    4

#define SYS_MMAP    9

#define SYS_MUNMAP  11

#define SYS_ACCESS  21

#define SYS_GETPID  39

#define SYS_CLONE   56
#define SYS_FORK    57
#define SYS_VFORK   58
#define SYS_EXECVE  59
#define SYS_EXIT    60
#define SYS_WAIT4   61

#define SYS_GETDENTS 78
#define SYS_GETCWD  79
#define SYS_CHDIR   80
#define SYS_FCHDIR  81

#define SYS_GETPPID 110

#ifndef KERNEL

typedef unsigned long long _arg_t;

static inline long _syscall_arg6(unsigned long long number,
    _arg_t arg1, _arg_t arg2, _arg_t arg3, _arg_t arg4, _arg_t arg5, _arg_t arg6) {
    register long long result;

    register long long rdi asm("rdi") = arg1;
    register long long rsi asm("rsi") = arg2;
    register long long rdx asm("rdx") = arg3;
    register long long r10 asm("r10") = arg4;
    register long long r8 asm("r8") = arg5;
    register long long r9 asm("r9") = arg6;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi),"r"(rsi),"r"(rdx),"r"(r10),"r"(r8),"r"(r9)
        :
        "%rbx","%rcx","%r11","memory"
    );

    asm volatile("":::"%rdi","%rsi","%rdx","%r10","%r8","%r9");

    return result;
}

static inline long _syscall_arg5(unsigned long long number,
    _arg_t arg1, _arg_t arg2, _arg_t arg3, _arg_t arg4, _arg_t arg5) {
    register long long result;

    register long long rdi asm("rdi") = arg1;
    register long long rsi asm("rsi") = arg2;
    register long long rdx asm("rdx") = arg3;
    register long long r10 asm("r10") = arg4;
    register long long r8 asm("r8") = arg5;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi),"r"(rsi),"r"(rdx),"r"(r10),"r"(r8)
        :
        "%r9","%rbx","%rcx","%r11","memory"
    );

    asm volatile("":::"%rdi","%rsi","%rdx","%r10","%r8");

    return result;
}

static inline long _syscall_arg4(unsigned long long number,
    _arg_t arg1, _arg_t arg2, _arg_t arg3, _arg_t arg4) {
    register long long result;

    register long long rdi asm("rdi") = arg1;
    register long long rsi asm("rsi") = arg2;
    register long long rdx asm("rdx") = arg3;
    register long long r10 asm("r10") = arg4;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi),"r"(rsi),"r"(rdx),"r"(r10)
        :
        "%r9","%r8","%rbx","%rcx","%r11","memory"
    );

    asm volatile("":::"%rdi","%rsi","%rdx","%r10");

    return result;
}

static inline long _syscall_arg3(unsigned long long number,
    _arg_t arg1, _arg_t arg2, _arg_t arg3) {
    register long long result;

    register long long rdi asm("rdi") = arg1;
    register long long rsi asm("rsi") = arg2;
    register long long rdx asm("rdx") = arg3;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi),"r"(rsi),"r"(rdx)
        :
        "%r9","%r8","%rbx","%rcx","%r10","%r11","memory"
    );

    asm volatile("":::"%rdi","%rsi","%rdx");

    return result;
}

static inline long _syscall_arg2(unsigned long long number,
    _arg_t arg1, _arg_t arg2) {
    register long long result;

    register long long rdi asm("rdi") = arg1;
    register long long rsi asm("rsi") = arg2;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi),"r"(rsi)
        :
        "%rdx","%r9","%r8","%rbx","%rcx","%r10","%r11","memory"
    );

    asm volatile("":::"%rdi","%rsi");

    return result;
}

static inline long _syscall_arg1(unsigned long long number, _arg_t arg1) {
    register long long result;

    register long long rdi asm("rdi") = arg1;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number),"r"(rdi)
        :
        "%rsi","%rdx","%r9","%r8","%rbx","%rcx","%r10","%r11","memory"
    );

    asm volatile("":::"%rdi");

    return result;
}

static inline long _syscall(unsigned long long number) {
    register long long result;

    asm volatile(
        "syscall \n"
        :"=a"(result)
        :[number]"a"(number)
        :
        "%rdi","%rsi","%rdx","%r9","%r8","%rbx","%rcx","%r10","%r11","memory"
    );

    return result;
}

#endif