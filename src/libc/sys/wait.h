#pragma once

#include "unistd.h"

pid_t wait4(pid_t pid, int* stat_loc, int options);

static inline pid_t waitpid(pid_t pid, int* stat_loc, int options) {
    return wait4(pid, stat_loc, options);
}