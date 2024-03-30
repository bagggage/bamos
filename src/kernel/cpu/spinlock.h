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

static volatile inline void spin_lock(Spinlock* spinlock) {
    while (__sync_lock_test_and_set(&spinlock->exclusion, 1)) {
        // Do nothing. This GCC builtin instruction
        // ensures memory barrier.
        while (spinlock->exclusion);
    }
}

static volatile inline void spin_release(Spinlock* spinlock) {
    __sync_lock_release(&spinlock->exclusion); // Memory barrier.
}