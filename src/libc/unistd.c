#include "unistd.h"

#include "sys/syscall.h"

pid_t fork() {
    return _syscall(SYS_FORK);
}

size_t read(unsigned int fd, char* buffer, size_t count) {
    return _syscall_arg3(SYS_READ, fd, (_arg_t)buffer, count);
}

size_t write(unsigned int fd, const char* buffer, size_t count) {
    return _syscall_arg3(SYS_WRITE, fd, (_arg_t)buffer, count);
}

int execve (const char* path, char* const argv[], char* const envp[]) {
    return _syscall_arg3(SYS_EXECVE, path, argv, envp);
}

int chdir(const char* path) {
    return _syscall_arg1(SYS_CHDIR, (_arg_t)path);
}

int fchdir(unsigned int fd) {
    return _syscall_arg1(SYS_FCHDIR, fd);
}

char* getcwd(char* restrict buffer, size_t size) {
    return _syscall_arg2(SYS_GETCWD, (_arg_t)buffer, size);
}

pid_t getpid() {
    return _syscall(SYS_GETPID);
}

pid_t getppid() {
    return _syscall(SYS_GETPPID);
}