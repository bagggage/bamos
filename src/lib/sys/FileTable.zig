//! # File Table
//! 
//! This is a structrue that is embedded to the `Process` struct and
//! used for handling and managment all open files within a process.

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

pub const Handle = packed struct {
    ptr: usize = 0,

    pub inline fn get(self: Handle) ?*vfs.File {
        @setRuntimeSafety(false);
        return @ptrFromInt(self.pointer());
    }

    pub inline fn set(self: *Handle, ptr: ?*vfs.File) void {
        self.ptr = @intFromPtr(ptr);
    }

    pub inline fn closeOnExec(self: Handle) bool {
        return (self.ptr & 1) != 0; 
    }

    pub inline fn setCloseOnExec(self: *Handle, value: bool) void {
        self.ptr = self.pointer() | @intFromBool(value);
    }

    fn pointer(self: Handle) usize {
        return self.ptr & (~@as(usize, 1));
    }
};

pub const Descriptor = struct {
    idx: u32,
    file: *vfs.File,
};

files: [*]Handle = undefined,
bitmap: lib.BitmapUnbounded = undefined,
lock: lib.sync.RwLock = .{},

capacity: u32 = 0,
max_files: u32 = 0,
num_files: u32 = 0,

pub fn init(max_files: u32) vm.Error!Self {
    const max_size = max_files * @sizeOf(?*vfs.File);

    if (max_size > vm.PageAllocator.max_alloc_pages * vm.page_size) return error.MaxSize;
    return .{ .max_files = max_files };
}

pub inline fn deinit(self: *Self) void {
    return bindings.getInstance().sys.file_table.deinit(self);
}

pub inline fn isFull(self: *Self) bool {
    self.lock.readLock();
    defer self.lock.readUnlock();

    return self.num_files >= self.max_files;
}

pub inline fn clone(self: *Self) vfs.Error!Self {
    return bindings.getInstance().sys.file_table.clone(self);
}

pub inline fn open(self: *Self, dentry: *vfs.Dentry, perm: vfs.Permissions) vfs.Error!Descriptor {
    return bindings.getInstance().sys.file_table.open(self, dentry, perm);
}

pub inline fn close(self: *Self, idx: u32) vfs.Error!void {
    return bindings.getInstance().sys.file_table.close(self, idx);
}

pub inline fn closeAll(self: *Self) void {
    bindings.getInstance().sys.file_table.closeAll(self);
}

pub inline fn closeOnExecute(self: *Self) void {
    bindings.getInstance().sys.file_table.closeOnExecute(self);
}

/// Duplicates descriptor.
/// Not increments reference counter of the new descriptor.
pub inline fn duplicate(self: *Self, idx: u32) vfs.Error!Descriptor {
    const file = self.get(idx) orelse return error.BadFileDescriptor;
    errdefer file.deref();

    return try self.newDescriptor(file);
}

/// Returns a file pointer and increments reference counter.
pub inline fn get(self: *Self, idx: u32) ?*vfs.File {
    return bindings.getInstance().sys.file_table.get(self, idx);
}

/// Returns a pointer to the descriptor handle if not null.
/// Not increments reference counter of the file.
pub inline fn getHandle(self: *Self, idx: u32) ?*Handle {
    return bindings.getInstance().sys.file_table.getHandle(self, idx);
}

pub inline fn setCloseOnExec(self: *Self, idx: u32, value: bool) bool {
    return bindings.getInstance().sys.file_table.setCloseOnExec(self, idx, value);
}

pub inline fn setMaxFiles(self: *Self, value: u32) vfs.Error!void {
    return bindings.getInstance().sys.file_table.setMaxFiles(self, value);
}

pub inline fn newDescriptor(self: *Self, file: *vfs.File) vfs.Error!Descriptor {
    return bindings.getInstance().sys.file_table.newDescriptor(self, file);
}

pub inline fn newDescriptors(self: *Self, buffer: []Descriptor) vfs.Error!void {
    return bindings.getInstance().sys.file_table.newDescriptors(self, buffer);
}

pub inline fn newDescriptorAt(self: *Self, idx: u32, file: *vfs.File, rebase: bool) vfs.Error!Descriptor {
    return bindings.getInstance().sys.file_table.newDescriptorAt(self, idx, file, rebase);
}
