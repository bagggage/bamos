//! # Spinlock
//! 
//! Provides a basic spinlock implementation using atomic operations.
//! A spinlock is a synchronization primitive used to protect shared resources
//! from concurrent access by multiple threads in a multiprocessor environment.
//! It "spins" in a loop, repeatedly checking if the lock is available.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const atomic = std.atomic;

const Self = @This();

exclusion: atomic.Value(u8) = atomic.Value(u8).init(@intFromEnum(State.unlocked)),

/// Represents the lock state
pub const State = enum(u1) {
    unlocked = 0,
    locked = 1,
};

/// Initializes a new spinlock with the specified initial state.
///
/// - `initial_state`: The initial state of the lock (either `locked` or `unlocked`).
pub inline fn init(initial_state: State) Self {
    return Self{
        .exclusion = atomic.Value(u8).init(@intFromEnum(initial_state))
    };
}

/// Attempts to acquire the lock. 
/// This function will spin in a loop until the lock is successfully acquired.
pub inline fn lock(self: *Self) void {
    while (self.exclusion.cmpxchgWeak(
        @intFromEnum(State.unlocked), @intFromEnum(State.locked),
        .acquire, .monotonic
    ) != null) {}
}

/// Releases the lock, making it available for others threads to acquire.
pub inline fn unlock(self: *Self) void {
    self.exclusion.store(@intFromEnum(State.unlocked), .release);
}

/// Checks if the spinlock is currently locked.
///
/// - Returns `true` if the spinlock is locked, `false` otherwise.
pub inline fn isLocked(self: *Self) bool {
    return self.exclusion.load(.unordered) != 0;
}

/// Wait until the lock is not in specified `state`.
pub fn wait(self: *Self, state: State) void {
    while (self.exclusion.load(.acquire) != @intFromEnum(state)) {
        continue;
    }
}