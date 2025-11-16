//! # Synchronization primitives

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const arch = @import("../lib.zig").arch;

pub const RwLock = @import("sync/RwLock.zig");
pub const Spinlock = @import("sync/Spinlock.zig");

pub inline fn halt() noreturn {
    while (true) arch.halt();
    unreachable;
}
