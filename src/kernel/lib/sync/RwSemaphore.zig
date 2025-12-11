//! # Read-Write Semaphore
//! 
//! Multiple readers and single writer lock mechanism that
//! calling scheduler to wait until the lock is freed.

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Self = @This();

const sched = @import("../../sched.zig");
const Spinlock = @import("Spinlock.zig");

wait_queue: sched.WaitQueue = .{},
readers: u32 = 0,
writing: bool = false,
lock: Spinlock = .init(.unlocked),

pub fn readLock(self: *Self) void {
    self.waitUntilWriting();
    defer self.lock.unlock();

    self.readers +%= 1;
}

pub fn readUnlock(self: *Self) void {
    self.lock.lock();
    defer self.lock.unlock();

    self.readers -%= 1;
}

pub fn writeLock(self: *Self) void {
    self.waitUntilWriting();

    self.writing = true;
    self.lock.unlock();

    while (@atomicLoad(u32, &self.readers, .acquire) > 0) sched.yield();
}

pub fn writeUnlock(self: *Self) void {
    {
        self.lock.lock();
        defer self.lock.unlock();

        self.writing = false;
    }

    sched.awakeAll(&self.wait_queue);
}

inline fn waitUntilWriting(self: *Self) void {
    self.lock.lock();
    while (self.writing) {
        sched.waitUnlock(&self.wait_queue, &self.lock);
        self.lock.lock();
    }
}