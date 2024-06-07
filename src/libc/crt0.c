#include "stdlib.h"
#include "stdio.h"
#include "fcntl.h"

extern int main();

static FILE stdin_fd;
static FILE stdout_fd;
static FILE stderr_fd;

static void __init() {
    stdin = &stdin_fd;
    stdout = &stdout_fd;
    stderr = &stderr_fd;

    stdin->_fileno =    open("/dev/tty0", O_RDONLY);
    stdout->_fileno =   open("/dev/tty0", O_WRONLY);
    stderr->_fileno =   open("/dev/tty0", O_WRONLY);
}

void _start() {
    __init();

    int result = main();

    exit(result);
}