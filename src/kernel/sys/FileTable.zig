//! # File Table
//! 
//! This is a structrue that is embedded to the `Process` struct and
//! used for handling and managment all open files within a process.

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

files: [*]?*vfs.File = undefined,
bitmap: lib.Bitmap = .{},
lock: lib.sync.Spinlock = .{},

// Capacity.
max_files: u32 = 0,
// Current number of allocated FDs.
num_files: std.atomic.Value(u32) = .init(0),

const Descriptor = struct {
    idx: u32,
    file: *vfs.File,
};

pub fn init(max_files: u32) vm.Error!Self {
    return .{
        .files = undefined,
        .max_files = max_files
    };
}

pub fn deinit(self: *Self) void {
    var num_files = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        // prevent further allocations
        break :blk self.num_files.swap(self.max_files, .release);
    };

    var i: u32 = 0;
    while (num_files > 0) : (i += 1) {
        if (self.files[i]) |f| {
            self.files[i] = null;
            f.deref();

            num_files -= 1;
        }
    }
}

pub fn clone(self: *const Self) vfs.Error!Self {
    var new: Self = undefined;
    try new.init(self.max_files);

    return error.BadOperation;
}

pub fn open(self: *Self, dentry: *vfs.Dentry, perm: vfs.Permissions) vfs.Error!Descriptor {
    const idx = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.num_files.load(.acquire) >= self.max_files) {
            @branchHint(.unlikely);
            return error.MaxSize;
        }

        _ = self.num_files.fetchAdd(1, .release);
        const idx = self.bitmap.find(false) orelse unreachable;
        self.bitmap.set(idx);

        break :blk idx;
    };
    errdefer self.num_files.fetchSub(1, .acquire);
    errdefer self.bitmap.clear(idx);

    const file = try dentry.open(perm);
    return .{
        .idx = idx,
        .file = file,
    };
}

pub fn close(self: *Self, idx: u32) void {
    const file = self.files[idx].?;
    self.files[idx] = null;

    self.bitmap.clear(idx);
    self.num_files.fetchSub(1, .acquire);

    file.deref();
}

pub fn get(self: *Self, idx: u32) ?*vfs.File {
    if (idx >= self.max_files) {
        @branchHint(.unlikely);
        return null;
    }

    const file = self.files[idx] orelse return null;
    return if (file.get()) file else null;
}
