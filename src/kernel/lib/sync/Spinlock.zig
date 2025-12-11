//! # Spinlock
//! 
//! Provides a basic spinlock implementation using atomic operations.
//! A spinlock is a synchronization primitive used to protect shared resources
//! from concurrent access by multiple threads in a multiprocessor environment.
//! It "spins" in a loop, repeatedly checking if the lock is available.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const smp = @import("../../smp.zig");
const sched = @import("../../sched.zig");
const intr = @import("../../dev.zig").intr;

const Self = @This();

exclusion: std.atomic.Value(State) = .init(.unlocked),

/// Represents the lock state.
pub const State = enum(u8) {
    locked_no_intr = 0,
    locked_intr = 1,
    unlocked = 2,
};

/// Initializes a new spinlock with the specified initial state.
/// 
/// - `locked`: The initial state of the lock.
pub inline fn init(init_state: enum{locked,unlocked}) Self {
    return Self{
        .exclusion = .init(
            if (init_state == .locked)
                .locked_intr else .unlocked
        )
    };
}

/// Disable preemtion.
/// Will spin in a loop until the lock is successfully acquired.
pub fn lock(self: *Self) void {
    sched.getCurrent().disablePreemption();
    self.rawLock(.locked_no_intr);
}

/// Saves the local state of interrupts and disables them on the current CPU.
/// Attempts to acquire the lock. 
/// Will spin in a loop until the lock is successfully acquired.
pub fn lockSaveIntr(self: *Self) void {
    comptime {
        std.debug.assert(@intFromBool(false) == @intFromEnum(State.locked_no_intr));
        std.debug.assert(@intFromBool(true) == @intFromEnum(State.locked_intr));
    }

    const state: State = @enumFromInt(@intFromBool(intr.saveAndDisableForCpu()));
    self.rawLock(state);
}

/// Acquire the lock, disable local interrupts.
pub inline fn lockIntr(self: *Self) void {
    intr.disableForCpu();
    self.rawLock(.locked_intr);
}

/// Attempts to acquire the lock. 
/// Will spin in a loop until the lock is successfully acquired.
/// 
/// Can be called **only** in atomic context (aka interrupts disabled)
pub inline fn lockAtomic(self: *Self) void {
    self.rawLock(.locked_no_intr);
}

/// Release the lock, enable preemtion.
pub inline fn unlock(self: *Self) void {
    self.unlockAtomic();
    sched.getCurrent().enablePreemption();
}

/// Restore local interrupt state and releases the lock.
pub fn unlockSaveIntr(self: *Self) void {
    const intr_enable = self.exclusion.raw == .locked_intr;

    self.unlockAtomic();
    intr.restoreForCpu(intr_enable);
}

/// Release the lock, enable local interrupts.
pub inline fn unlockIntr(self: *Self) void {
    self.unlockAtomic();
    intr.enableForCpu();
}

/// Release the lock.
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

pub fn tryLock(self: *Self) bool {
    const state: State = if (intr.saveAndDisableForCpu()) .locked_intr else .locked_no_intr;
    return self.exclusion.cmpxchgStrong(
        .unlocked, state,
        .acquire, .monotonic
    ) == null;
}

pub inline fn tryLockAtomic(self: *Self) bool {
    return self.exclusion.cmpxchgStrong(
        .unlocked, .locked_no_intr,
        .acquire, .monotonic
    ) == null;
}

inline fn rawLock(self: *Self, lock_state: State) void {
    while (self.exclusion.cmpxchgWeak(
        .unlocked, lock_state,
        .acquire, .monotonic
    ) != null) {
        std.atomic.spinLoopHint();
    }
}