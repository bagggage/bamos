//! # Pipe

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Self = @This();

const bindings = @import("../bindings.zig");
const File = vfs.File;
const lib = @import("../lib.zig");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const RingBuffer = lib.RingBuffer(u8);

pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

buffer: RingBuffer = .{},
ref_counter: lib.atomic.RefCount(u16) = .{},
readers: std.atomic.Value(u16) = .init(0), 
writers: std.atomic.Value(u16) = .init(0), 

mutex: lib.sync.Mutex = .{},

wait_lock: lib.sync.Spinlock = .{},
read_wait: sched.WaitQueue = .{},
write_wait: sched.WaitQueue = .{},

/// Creates new pipe and two `vfs.File` ends:
/// `[0]` - read(in), `[1]` - write(out).
pub inline fn create(size: u16) vm.Error![2]*File {
    return bindings.getInstance().vfs.pipe.create(size);
}

pub inline fn delete(self: *Self) void {
    return bindings.getInstance().vfs.pipe.delete(self);
}
