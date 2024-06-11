#include "stdlib.h"
#include "stdio.h"
#include "fcntl.h"

#define TTY_FILENAME "/dev/tty"

extern int main();

static FILE stdin_fd;
static FILE stdout_fd;
static FILE stderr_fd;

void __init(long long argc, char** argv, char** envp) {
    environ = envp;

    stdin = &stdin_fd;
    stdout = &stdout_fd;
    stderr = &stderr_fd;

    stdin->_fileno =    open(TTY_FILENAME, O_RDONLY);
    stdout->_fileno =   open(TTY_FILENAME, O_WRONLY);
    stderr->_fileno =   open(TTY_FILENAME, O_WRONLY);
}

__asm__(
    ".global _start \n"
    "_start: \n"
    "pop %rbx \n"
    "pop %r12 \n"
    "pop %r13 \n"
    "and $0xfffffffffffffff0,%rsp \n"
    "sub $8,%rsp \n"
    "mov %rsp,%rbp \n"
    "xor %rax,%rax \n"
    "xor %rcx,%rcx \n"
    "xor %r8,%r8 \n"
    "xor %r9,%r9 \n"
    "xor %r10,%r10 \n"
    "xor %r11,%r11 \n"
    "mov %rbx,%rdi \n"
    "mov %r12,%rsi \n"
    "mov %r13,%rdx \n"
    "call __init \n"
    "mov %rbx,%rdi \n"
    "mov %r12,%rsi \n"
    "mov %r13,%rdx \n"
    "call main \n"
    "mov %rdi,%rax \n"
    "call exit"
);