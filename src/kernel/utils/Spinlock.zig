//! # Spinlock
//! 
//! Provides a basic spinlock implementation using atomic operations.
//! A spinlock is a synchronization primitive used to protect shared resources
//! from concurrent access by multiple threads in a multiprocessor environment.
//! It "spins" in a loop, repeatedly checking if the lock is available.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const atomic = std.atomic;
const std = @import("std");
const smp = @import("../smp.zig");
const intr = @import("../dev.zig").intr;

const Self = @This();

exclusion: atomic.Value(State) = .init(.unlocked),

/// Represents the lock state.
pub const State = enum(u8) {
    unlocked = 0,
    locked_no_intr = 1,
    locked_intr = 2
};

/// Initializes a new spinlock with the specified initial state.
/// 
/// - `locked`: The initial state of the lock: `true` - locked, `false` - unlocked.
pub inline fn init(init_state: enum{locked,unlocked}) Self {
    return Self{
        .exclusion = .init(
            if (init_state == .locked)
                .locked_intr else .unlocked
        )
    };
}

/// Saves the local state of interrupts and disables them on the current CPU.
/// Attempts to acquire the lock. 
/// Will spin in a loop until the lock is successfully acquired.
pub fn lock(self: *Self) void {
    const state: State = if (intr.saveAndDisableForCpu())
        .locked_intr else .locked_no_intr;
    self.rawLock(state);
}

/// Attempts to acquire the lock. 
/// Will spin in a loop until the lock is successfully acquired.
/// 
/// Can be called **only** in atomic context (aka interrupts disabled)
pub inline fn lockAtomic(self: *Self) void {
    self.rawLock(.locked_no_intr);
}

/// Restore local interrupt state and releases the lock.
pub fn unlock(self: *Self) void {
    const intr_enable = self.exclusion.raw == .locked_intr;

    self.unlockAtomic();
    intr.restoreForCpu(intr_enable);
}

/// Releases the lock.
/// 
/// Can be called **only** in atomic context (aka interrupts disabled)
pub inline fn unlockAtomic(self: *Self) void {
    self.exclusion.store(.unlocked, .release);
}

/// Checks if the spinlock is currently locked.
///
/// - Returns `true` if the spinlock is locked, `false` otherwise.
pub inline fn isLocked(self: *Self) bool {
    return self.exclusion.load(.unordered) != .unlocked;
}

/// Wait until the lock is not in specified `state`.
pub fn wait(self: *Self, state: State) void {
    while (self.exclusion.load(.acquire) != state) {
        std.atomic.spinLoopHint();
    }
}

inline fn rawLock(self: *Self, lock_state: State) void {
    while (self.exclusion.cmpxchgWeak(
        State.unlocked, lock_state,
        .acquire, .monotonic
    ) != null) {
        std.atomic.spinLoopHint();
    }
}