const atomic = @import("std").atomic;
const AtomicOrder = @import("std").builtin.AtomicOrder;

exclusion: atomic.Value(u8) = atomic.Value(u8).init(UNLOCKED),

pub const LOCKED = 1;
pub const UNLOCKED = 0;

const Self = @This();

pub inline fn init(initial_state: comptime_int) Self {
    return Self{ .exclusion = atomic.Value(u8).init(initial_state) };
}

pub inline fn lock(self: *Self) void {
    while (self.exclusion.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {}
}

pub inline fn unlock(self: *Self) void {
    self.exclusion.store(UNLOCKED, .release);
}

pub inline fn isLocked(self: *Self) bool {
    return self.exclusion.load(.unordered) != 0;
}