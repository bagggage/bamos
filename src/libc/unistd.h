#pragma once

typedef int pid_t;
typedef unsigned long long intptr_t;
typedef unsigned long long size_t;

pid_t fork();

size_t read(unsigned int fd, char* buffer, size_t count);
size_t write(unsigned int fd, const char* buffer, size_t count);

//execv();
//
int execve(const char* path, char* const argv[], char* const envp[]);
//
//execvp();
//
//getpid();

int chdir(const char* path);
int fchdir(unsigned int fd);

char* getcwd(char* restrict buffer, size_t size);

pid_t getpid();
pid_t getppid();