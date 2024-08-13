//! # Spinlock
//! Provides a basic spinlock implementation using atomic operations. 
//! A spinlock is a synchronization primitive used to protect shared resources 
//! from concurrent access by multiple threads in a multiprocessor environment.
//! It "spins" in a loop, repeatedly checking if the lock is available.

const atomic = @import("std").atomic;
const AtomicOrder = @import("std").builtin.AtomicOrder;

exclusion: atomic.Value(u8) = atomic.Value(u8).init(UNLOCKED),

/// Represents the lock state for when the spinlock is locked.
pub const LOCKED = 1;
/// Represents the lock state for when the spinlock is unlocked.
pub const UNLOCKED = 0;

const Self = @This();

/// Initializes a new spinlock with the specified initial state.
///
/// - `initial_state`: The initial state of the lock (either `LOCKED` or `UNLOCKED`).
pub inline fn init(initial_state: comptime_int) Self {
    return Self{ .exclusion = atomic.Value(u8).init(initial_state) };
}

/// Attempts to acquire the lock. 
/// This function will spin in a loop until the lock is successfully acquired.
pub inline fn lock(self: *Self) void {
    while (self.exclusion.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {}
}

/// Releases the lock, making it available for others threads to acquire.
pub inline fn unlock(self: *Self) void {
    self.exclusion.store(UNLOCKED, .release);
}

/// Checks if the spinlock is currently locked.
///
/// - Returns `true` if the spinlock is locked, `false` otherwise.
pub inline fn isLocked(self: *Self) bool {
    return self.exclusion.load(.unordered) != 0;
}