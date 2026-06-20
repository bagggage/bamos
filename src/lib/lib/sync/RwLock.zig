//! # Read-Write Lock
//! 
//! Multiple readers and single writer lock mechanism.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const Self = @This();

const sched = @import("../../sched.zig");
const Spinlock = @import("Spinlock.zig");

lock: Spinlock = .init(.unlocked),
readers: std.atomic.Value(u16) = .init(0),

pub inline fn readLock(self: *Self) void {
    bindings.getInstance().lib.rw_lock.readLock(self);
}

pub inline fn tryReadLock(self: *Self) bool {
    return bindings.getInstance().lib.rw_lock.tryReadLock(self);
}

pub inline fn readUnlock(self: *Self) void {
    _ = self.readers.fetchSub(1, .acquire);
    sched.getCurrent().enablePreemption();
}

pub fn writeLock(self: *Self) void {
    self.lock.lock();

    while (self.readers.load(.acquire) > 0) {
        @branchHint(.unlikely);
        std.atomic.spinLoopHint();
    }
}

pub fn tryWriteLock(self: *Self) bool {
    if (self.readers.load(.release) > 0) return false;
    if (self.lock.tryLock() == false) return false;

    if (self.readers.load(.release) > 0) {
        self.lock.unlock();
        return false;
    }

    return true;
}

pub inline fn writeUnlock(self: *Self) void {
    self.lock.unlock();
}

inline fn waitForRead(self: *Self) void {
    while (self.lock.isLocked()) {
        @branchHint(.unlikely);
        std.atomic.spinLoopHint();
    }
}
