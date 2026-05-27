const sync = @import("../../src/kernel/lib/sync.zig");
const t = @import("../framework.zig");

pub fn @"spinlock.init reflects state"() !void {
    var unlocked = sync.Spinlock.init(.unlocked);
    var locked = sync.Spinlock.init(.locked);

    try t.expect(!unlocked.isLocked());
    try t.expect(locked.isLocked());
}

pub fn @"spinlock.tryLockAtomic round trip"() !void {
    var lock = sync.Spinlock.init(.unlocked);

    try t.expect(lock.tryLockAtomic());
    try t.expect(lock.isLocked());
    try t.expect(!lock.tryLockAtomic());

    lock.unlockAtomic();
    try t.expect(!lock.isLocked());
}

pub fn @"spinlock.tryLock round trip"() !void {
    var lock = sync.Spinlock.init(.unlocked);

    try t.expect(lock.tryLock());
    try t.expect(lock.isLocked());

    lock.unlock();
    try t.expect(!lock.isLocked());
}

pub fn @"spinlock.lockTimeout fails for held lock"() !void {
    var lock = sync.Spinlock.init(.locked);

    try t.expectError(error.Timeout, lock.lockTimeout(0));
    try t.expect(lock.isLocked());
}

pub fn @"mutex.init reflects state"() !void {
    var unlocked = sync.Mutex.init(.unlocked);
    var locked = sync.Mutex.init(.locked);

    try t.expect(!unlocked.isLocked());
    try t.expect(locked.isLocked());
}

pub fn @"mutex.tryLock round trip"() !void {
    var mutex = sync.Mutex.init(.unlocked);

    try t.expect(mutex.tryLock());
    try t.expect(mutex.isLocked());

    mutex.unlock();
    try t.expect(!mutex.isLocked());
}

pub fn @"mutex.tryLockAtomic rejects locked mutex"() !void {
    var mutex = sync.Mutex.init(.locked);

    try t.expect(!mutex.tryLockAtomic());
    try t.expect(mutex.isLocked());
}

pub fn @"mutex.unlockRestoreIntr releases save-intr lock"() !void {
    var mutex: sync.Mutex = .{};

    mutex.lockSaveIntr();
    mutex.unlockRestoreIntr();

    try t.expect(!mutex.isLocked());
}

pub fn @"rwlock.readLock round trip"() !void {
    var rw: sync.RwLock = .{};

    rw.readLock();
    try t.expectEqual(@as(u16, 1), rw.readers.load(.acquire));

    rw.readUnlock();
    try t.expectEqual(@as(u16, 0), rw.readers.load(.acquire));
}

pub fn @"rwlock.tryReadLock fails during write"() !void {
    var rw: sync.RwLock = .{};
    rw.lock.lockAtomic();
    defer rw.lock.unlockAtomic();

    try t.expect(!rw.tryReadLock());
}

pub fn @"rwlock.tryWriteLock fails with reader"() !void {
    var rw: sync.RwLock = .{};

    try t.expect(rw.tryReadLock());
    defer rw.readUnlock();

    try t.expect(!rw.tryWriteLock());
}

pub fn @"rwlock.tryWriteLock round trip"() !void {
    var rw: sync.RwLock = .{};

    try t.expect(rw.tryWriteLock());
    try t.expect(rw.lock.isLocked());

    rw.writeUnlock();
    try t.expect(!rw.lock.isLocked());
}

pub fn @"rwsemaphore.readLock round trip"() !void {
    var semaphore: sync.RwSemaphore = .{};

    semaphore.readLock();
    try t.expectEqual(@as(u32, 1), semaphore.readers);
    try t.expect(!semaphore.writing);

    semaphore.readUnlock();
    try t.expectEqual(@as(u32, 0), semaphore.readers);
}

pub fn @"rwsemaphore.writeLock round trip"() !void {
    var semaphore: sync.RwSemaphore = .{};

    semaphore.writeLock();
    try t.expect(semaphore.writing);
    try t.expectEqual(@as(u32, 0), semaphore.readers);

    semaphore.writeUnlock();
    try t.expect(!semaphore.writing);
}

pub fn @"rwsemaphore.writeToReadLock downgrades writer"() !void {
    var semaphore: sync.RwSemaphore = .{};

    semaphore.writeLock();
    semaphore.writeToReadLock();

    try t.expect(!semaphore.writing);
    try t.expectEqual(@as(u32, 1), semaphore.readers);

    semaphore.readUnlock();
    try t.expectEqual(@as(u32, 0), semaphore.readers);
}
