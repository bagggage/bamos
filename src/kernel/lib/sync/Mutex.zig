//! # Mutex

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const Spinlock = @import("Spinlock.zig");
const intr = @import("../../dev.zig").intr;

const Self = @This();

wait_queue: sched.WaitQueue = .{},
spinlock: Spinlock = .{},
wait_lock: Spinlock = .{},

pub inline fn init(init_state: enum{locked,unlocked}) Self {
    return .{ .spinlock = .init(init_state)  };
}

pub fn lock(self: *Self) void {
    while (true) {
        sched.getCurrent().disablePreemption();

        for (0..8) |_| if (self.spinlock.tryLockWeakAtomic()) return;
        if (self.wait_lock.tryLockAtomic()) {
            sched.waitUnlock(&self.wait_queue, &self.wait_lock, false) catch unreachable;
        } else {
            sched.getCurrent().enablePreemption();
        }
    }
}

pub inline fn lockKeepPreemption(self: *Self) void {
    self.lock();
    sched.getCurrent().enablePreemption();
}

pub fn unlockKeepPreemption(self: *Self) void {
    self.wait_lock.lock();
    defer self.wait_lock.unlock();

    self.spinlock.unlockAtomic();
    sched.awakeAll(&self.wait_queue);
}

pub fn lockSaveIntr(self: *Self) void {
    defer sched.getCurrent().enablePreemptionRaw();

    while (true) {
        sched.getCurrent().disablePreemption();
        const intr_enabled = intr.saveAndDisableForCpu();

        for (0..8) |_| if (self.spinlock.tryLockWeakAtomic()) {
            self.spinlock.exclusion.raw = if (intr_enabled) .locked_intr else .locked_no_intr;
            return;
        };

        intr.restoreForCpu(intr_enabled);

        if (self.wait_lock.tryLockAtomic()) {
            sched.waitUnlock(&self.wait_queue, &self.wait_lock, false) catch unreachable;
        } else {
            sched.getCurrent().enablePreemption();
        }
    }
}

/// Acquire the lock, disable local interrupts.
pub fn lockIntr(self: *Self) void {
    defer sched.getCurrent().enablePreemptionRaw();

    while (true) {
        sched.getCurrent().disablePreemption();

        if (self.spinlock.tryLockIntr()) return;
        if (self.wait_lock.tryLockAtomic()) {
            sched.waitUnlock(&self.wait_queue, &self.wait_lock, false) catch unreachable;
        } else {
            sched.getCurrent().enablePreemption();
        }
    }
}

/// Release the lock, enable preemtion.
pub fn unlock(self: *Self) void {
    self.spinlock.unlockAtomic();
    defer sched.getCurrent().enablePreemption();

    self.wait_lock.lockAtomic();
    defer self.wait_lock.unlockAtomic();

    sched.awakeAll(&self.wait_queue);
}

/// Restore local interrupt state and releases the lock.
pub fn unlockRestoreIntr(self: *Self) void {
    const intr_enable = self.exclusion.raw == .locked_intr;
    if (intr_enable) {
        self.unlockIntr();
    } else {
        self.spinlock.unlockAtomic();
    }
}

/// Release the lock, enable local interrupts.
pub fn unlockIntr(self: *Self) void {
    sched.getCurrent().disablePreemption();

    self.spinlock.unlockAtomic();
    defer sched.getCurrent().enablePreemption();

    intr.enableForCpu();

    self.wait_lock.lockAtomic();
    defer self.wait_lock.unlockAtomic();

    sched.awakeAll(&self.wait_queue);
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

pub fn tryLockSaveIntr(self: *Self) bool {
    return self.spinlock.tryLockSaveIntr();
}

pub inline fn tryLockAtomic(self: *Self) bool {
    return self.spinlock.tryLockAtomic();
}
