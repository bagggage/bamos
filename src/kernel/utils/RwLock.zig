//! # Read-Write Lock
//! 
//! Multiple readers and single writer lock mechanism.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Self = @This();

const atomic = std.atomic;
const sched = @import("../sched.zig");
const Spinlock = @import("Spinlock.zig");

lock: Spinlock = .init(.unlocked),
readers: atomic.Value(u16) = .init(0),

pub fn readLock(self: *Self) void {
    self.waitForRead();
    defer self.waitForRead();

    sched.getCurrent().disablePreemption();
    _ = self.readers.fetchAdd(1, .release);
}

pub fn tryReadLock(self: *Self) bool {
    if (self.lock.isLocked()) {
        @branchHint(.unlikely);
        return false;
    }

    const scheduler = sched.getCurrent();
    scheduler.disablePreemption();
    self.readers.fetchAdd(1, .release);

    if (self.lock.isLocked()) {
        @branchHint(.unlikely);

        self.readers.fetchSub(1, .acquire);
        scheduler.enablePreemption();
        return false;
    }

    return true;
}

pub fn readUnlock(self: *Self) void {
    self.readers.fetchSub(1, .acquire);
    sched.getCurrent().enablePreemption();
}

pub fn writeLock(self: *Self) void {
    self.lock.lock();

    while (self.readers.load(.release) > 0) {
        @branchHint(.unlikely);
        atomic.spinLoopHint();
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
        atomic.spinLoopHint();
    }
}