//! # Kernel utilities library

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

pub const is_debug = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe);

/// Fixed-point scale.
pub const fp_scale = 32;

pub const byte_size = 8;
pub const kb_size = 1024;
pub const mb_size = kb_size * 1024;
pub const gb_size = mb_size * 1024;

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86-64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const AnyData = struct {
    ptr: ?*anyopaque = null,

    pub inline fn from(ptr: ?*anyopaque) AnyData {
        return .{ .ptr = ptr };
    }

    pub inline fn set(self: *AnyData, ptr: ?*anyopaque) void {
        self.ptr = ptr;
    }

    pub inline fn as(self: AnyData, comptime T: type) ?*T {
        return if (self.ptr) |val| @as(*T, @ptrCast(@alignCast(val))) else null;
    }
};

pub const atomic = @import("lib/atomic.zig");
pub const AutoHashTable = hash_table.AutoHashTable;
pub const BinaryTree = @import("lib/binary-tree.zig").BinaryTree;
pub const Bitmap = @import("lib/Bitmap.zig");
pub const hash_table = @import("lib/hash-table.zig");
pub const HashTable = hash_table.HashTable;
pub const Heap = @import("lib/Heap.zig");
pub const meta = @import("lib/meta.zig");
pub const misc = @import("lib/misc.zig");
pub const NumberAlloc = num_alloc.NumberAlloc;
pub const NumberAllocCeil = num_alloc.NumberAllocCeil;
pub const NumberAllocFloor = num_alloc.NumberAllocFloor;
pub const NumberAllocRanged = num_alloc.NumberAllocRanged;
pub const rb = @import("lib/rb-tree.zig");
pub const rcu = @import("lib/rcu.zig");
pub const sync = @import("lib/sync.zig");

const num_alloc = @import("lib/num-alloc.zig");
