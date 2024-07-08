#include "wait.h"

#include "syscall.h"

pid_t wait4(pid_t pid, int* stat_loc, int options) {
    return _syscall_arg3(SYS_WAIT4, pid, (_arg_t)stat_loc, options);
}