//! # Mutex

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");

const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const Spinlock = @import("Spinlock.zig");

const Self = @This();

wait_queue: sched.WaitQueue = .{},
spinlock: Spinlock = .{},
wait_lock: Spinlock = .{},

pub inline fn init(init_state: enum{locked,unlocked}) Self {
    return .{ .spinlock = .init(init_state)  };
}

pub inline fn lock(self: *Self) void {
    bindings.getInstance().lib.mutex.lock(self);
}

pub inline fn lockSaveIntr(self: *Self) void {
    bindings.getInstance().lib.mutex.lockSaveIntr(self);
}

/// Acquire the lock, disable local interrupts.
pub inline fn lockIntr(self: *Self) void {
    bindings.getInstance().lib.mutex.lockIntr(self);
}

/// Release the lock, enable preemtion.
pub inline fn unlock(self: *Self) void {
    bindings.getInstance().lib.mutex.unlock(self);
}

/// Restore local interrupt state and releases the lock.
pub inline fn unlockRestoreIntr(self: *Self) void {
    bindings.getInstance().lib.mutex.unlockRestoreIntr(self);
}

/// Release the lock, enable local interrupts.
pub inline fn unlockIntr(self: *Self) void {
    bindings.getInstance().lib.mutex.unlockIntr(self);
}

pub inline fn isLocked(self: *Self) bool {
    return self.spinlock.isLocked();
}

pub inline fn tryLock(self: *Self) bool {
    return self.spinlock.tryLock();
}

pub inline fn tryLockIntr(self: *Self) bool {
    return self.spinlock.tryLockIntr();
}

pub inline fn tryLockSaveIntr(self: *Self) bool {
    return self.spinlock.tryLockSaveIntr();
}

pub inline fn tryLockAtomic(self: *Self) bool {
    return self.spinlock.tryLockAtomic();
}
