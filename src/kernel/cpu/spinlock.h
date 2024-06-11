#pragma once

#include "definitions.h"

/*
Kernel-space spinlock.
*/

typedef struct Spinlock {
    volatile uint8_t exclusion;
} Spinlock;

static inline Spinlock spinlock_init() {
    Spinlock lock = { 0 };
    return lock;
}

static inline void spin_lock(Spinlock* const spinlock) {
    while (__sync_lock_test_and_set(&spinlock->exclusion, 1)) {
        // Do nothing. This GCC builtin instruction
        // ensures memory barrier.
        while (spinlock->exclusion);
    }
}

static inline void spin_release(Spinlock* const spinlock) {
    __sync_lock_release(&spinlock->exclusion); // Memory barrier.
}