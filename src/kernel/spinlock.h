#pragma once

#include "definitions.h"

enum LockState : uint8_t {
    LOCK_UNLOCKED = 0,
    LOCK_LOCKED = 1
};

class Spinlock {
private:
    uint8_t exclusion = 0;
public:
    Spinlock(const LockState init_state = LOCK_UNLOCKED)
    : exclusion(init_state)
    {};

    inline void lock() {
        while (__sync_lock_test_and_set(&exclusion, 1)) {
            // Do nothing. This GCC builtin instruction
            // ensures memory barrier.
            while (exclusion);
        }
    }

    inline void release() {
        // Memory barrier
        __sync_lock_release(&exclusion);
    }
};