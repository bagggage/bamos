//! # File Table
//! 
//! This is a structrue that is embedded to the `Process` struct and
//! used for handling and managment all open files within a process.

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();

const min_capacity = 16;
const min_bitmap_byte_len = 16;

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

files: [*]Handle = undefined,
bitmap: lib.BitmapUnbounded = undefined,
lock: lib.sync.RwLock = .{},

capacity: u32 = 0,
max_files: u32 = 0,
num_files: u32 = 0,

const Descriptor = struct {
    idx: u32,
    file: *vfs.File,
};

pub fn init(max_files: u32) vm.Error!Self {
    const max_size = max_files * @sizeOf(?*vfs.File);

    if (max_size > vm.PageAllocator.max_alloc_pages * vm.page_size) return error.MaxSize;
    return .{ .max_files = max_files };
}

pub fn deinit(self: *Self) void {
    const capacity, var num_files = blk: {
        self.lock.writeLock();
        defer self.lock.writeUnlock();

        // prevent further allocations
        defer self.num_files = 0;
        defer self.capacity = 0;
        break :blk .{ self.capacity, self.num_files };
    };

    var i: u32 = 0;
    while (num_files > 0) : (i += 1) {
        if (self.files[i].get()) |f| {
            self.files[i].set(null);
            f.deref();

            num_files -= 1;
        }
    }

    if (capacity == 0) return;

    self.freeArray();
    vm.gpa.free(self.bitmap.bytes);
}

pub inline fn isFull(self: *Self) bool {
    self.lock.readLock();
    defer self.lock.readUnlock();

    return self.num_files >= self.max_files;
}

pub fn clone(self: *Self) vfs.Error!Self {
    self.lock.readLock();
    defer self.lock.readUnlock();

    const bitmap_size = bitmapSize(self.capacity);
    const bitmap = vm.gpa.allocMany(u8, bitmap_size) orelse return error.NoMemory;
    errdefer vm.gpa.free(bitmap.ptr);

    const array = try allocArray(self.capacity);
    var num_files: u32 = 0;
    for (0..self.capacity) |i| {
        if (num_files >= self.num_files) {
            @memset(array[i..self.capacity], .{});
            break;
        }

        const file = self.files[i].get() orelse {
            array[i].set(null);
            continue;
        };

        array[i].set(file);
        file.ref();
        num_files += 1;
    }

    @memcpy(bitmap, self.bitmap.bytes[0..bitmap.len]);

    return .{
        .files = array,
        .bitmap = .{ .bytes = bitmap.ptr },
        .capacity = self.capacity,
        .max_files = self.max_files,
        .num_files = self.num_files
    };
}

pub fn open(self: *Self, dentry: *vfs.Dentry, perm: vfs.Permissions) vfs.Error!Descriptor {
    const file = try dentry.open(perm);
    return try self.newDescriptor(file);
}

pub fn close(self: *Self, idx: u32) vfs.Error!void {
    const file = blk: {
        self.lock.writeLock();
        defer self.lock.writeUnlock();

        const file = self.files[idx].get() orelse return error.BadFileDescriptor;
        self.files[idx].set(null);

        self.bitmap.clear(idx);
        self.num_files -= 1;

        break :blk file;
    };

    file.deref();
}

pub fn closeAll(self: *Self) void {
    self.lock.writeLock();
    defer self.lock.writeUnlock();
    defer self.num_files = 0;
    defer self.bitmap.clearAll(self.capacity);

    var num_files = 0;
    for (0..self.capacity) |i| {
        if (num_files >= self.num_files) break;

        const file = self.files[i].get() orelse continue;
        self.files[i].set(null);
        file.deref();

        num_files += 1;
    }
}

pub fn closeOnExecute(self: *Self) void {
    self.lock.writeLock();
    defer self.lock.writeUnlock();

    var num_files: u32 = 0;
    for (0..self.capacity) |i| {
        if (num_files >= self.num_files) break;

        const handle = self.files[i];
        const file = handle.get() orelse continue;
        defer num_files += 1;

        if (!handle.closeOnExec()) continue;

        self.files[i].set(null);
        self.bitmap.clear(i);
        self.num_files -= 1;

        file.deref();
    }
}

/// Duplicates descriptor.
/// Not increments reference counter of the new descriptor.
pub inline fn duplicate(self: *Self, idx: u32) vfs.Error!Descriptor {
    const file = self.get(idx) orelse return error.BadFileDescriptor;
    defer file.deref();

    return try self.newDescriptor(file);
}

/// Returns a file pointer and increments reference counter.
pub fn get(self: *Self, idx: u32) ?*vfs.File {
    self.lock.readLock();
    defer self.lock.readUnlock();

    if (idx >= self.capacity) {
        @branchHint(.unlikely);
        return null;
    }

    const file = self.files[idx].get() orelse return null;
    return if (file.get()) file else null;
}

/// Returns a pointer to the descriptor handle if not null.
/// Not increments reference counter of the file.
pub fn getHandle(self: *Self, idx: u32) ?*Handle {
    self.lock.readLock();
    defer self.lock.readUnlock();

    if (idx >= self.capacity) {
        @branchHint(.unlikely);
        return null;
    }

    const handle = &self.files[idx];
    if (handle.get() == null) return null;

    return handle;
}

pub fn setCloseOnExec(self: *Self, idx: u32, value: bool) bool {
    self.lock.writeLock();
    defer self.lock.writeUnlock();

    if (self.files[idx].ptr == 0) return false;
    self.files[idx].setCloseOnExec(value);

    return true;
}

pub fn setMaxFiles(self: *Self, value: u32) vfs.Error!void {
    const max_size = @as(usize, value) * @sizeOf(Handle);
    if (max_size > vm.PageAllocator.max_alloc_pages * vm.page_size) return error.MaxSize;

    self.lock.writeLock();
    defer self.lock.writeUnlock();

    if (value < self.num_files) return error.Busy;
    self.max_files = value;
}

pub fn newDescriptor(self: *Self, file: *vfs.File) vfs.Error!Descriptor {
    self.lock.writeLock();
    defer self.lock.writeUnlock();

    if (self.num_files >= self.max_files) {
        @branchHint(.unlikely);
        return error.MaxSize;
    }

    try self.ensureCapacity(self.num_files + 1);

    const idx = self.bitmap.find(self.capacity, false) orelse unreachable;
    std.debug.assert(idx < self.capacity);

    self.bitmap.set(idx);
    self.files[idx].set(file);
    self.num_files += 1;

    file.ref();
    return .{ .idx = @truncate(idx), .file = file };
}

pub fn newDescriptorAt(self: *Self, idx: u32, file: *vfs.File, rebase: bool) vfs.Error!Descriptor {
    self.lock.writeLock();
    defer self.lock.writeUnlock();

    if (self.num_files >= self.max_files) {
        @branchHint(.unlikely);
        return error.MaxSize;
    }

    try self.ensureCapacity(idx + 1);

    const fd_idx = if (self.bitmap.get(idx) != 0) blk: {
        if (!rebase) { // Replace
            const old_file = self.files[idx].get().?;
            defer old_file.deref();

            file.ref();
            self.files[idx].set(file);

            return .{ .idx = @truncate(idx), .file = file };
        }
        for (idx + 1..self.capacity) |i| {
            if (self.bitmap.get(i) == 0) break :blk i;
        }
        return error.MaxSize;
    } else idx;

    std.debug.assert(fd_idx < self.capacity);

    self.bitmap.set(fd_idx);
    self.files[fd_idx].set(file);
    self.num_files += 1;
    file.ref();

    return .{ .idx = @truncate(fd_idx), .file = file };
}

fn ensureCapacity(self: *Self, value: u32) !void {
    const new_capacity = std.math.ceilPowerOfTwo(u32, value) catch return error.NoMemory;
    if (self.capacity == 0) {
        const capacity = @max(new_capacity, min_capacity);
        const bitmap_size = bitmapSize(capacity);
        const bitmap = vm.gpa.allocMany(u8, bitmap_size) orelse return error.NoMemory;
        errdefer vm.gpa.free(bitmap.ptr);

        self.files = try allocArray(capacity);
        @memset(self.files[0..capacity], .{});

        self.bitmap = .init(bitmap[0..bitmap_size], false);
        self.capacity = capacity;
    } else if (new_capacity > self.capacity) {
        const bitmap_size = bitmapSize(self.capacity);
        if (new_capacity > bitmap_size * lib.byte_size) {
            const new_bitmap_size = bitmapSize(new_capacity);
            const bitmap = vm.gpa.allocMany(u8, new_bitmap_size) orelse return error.NoMemory;

            @memcpy(bitmap[0..bitmap_size], self.bitmap.bytes[0..bitmap_size]);
            @memset(bitmap[bitmap_size..], 0);

            vm.gpa.free(self.bitmap.bytes);
            self.bitmap.bytes = bitmap.ptr;
        }

        const array = try allocArray(new_capacity);
        @memcpy(array[0..self.capacity], self.files[0..self.capacity]);
        @memset(array[self.capacity..new_capacity], .{});

        self.freeArray();
        self.files = array;
        self.capacity = new_capacity;
    }
}

fn allocArray(capacity: usize) ![*]Handle {
    if (capacity >= vm.page_size) {
        const size = capacity * @sizeOf(Handle);
        const phys = vm.PageAllocator.alloc(vm.bytesToRank(size)) orelse return error.NoMemory;

        return @ptrFromInt(vm.getVirtLma(phys));
    }

    const slice = vm.gpa.allocMany(Handle, capacity) orelse return error.NoMemory;
    return slice.ptr;
}

inline fn freeArray(self: *const Self) void {
    if (self.capacity * @sizeOf(?*vfs.File) >= vm.page_size) {
        const rank = vm.bytesToRank(self.capacity);
        const phys = vm.getPhysLma(self.files);
        vm.PageAllocator.free(phys, rank);
    } else {
        vm.gpa.free(@ptrCast(self.files));
    }
}

inline fn bitmapSize(capacity: usize) usize {
    const byte_len = (capacity + (lib.byte_size - 1)) >> lib.byte_shift;
    const log2_len = std.math.log2_int_ceil(usize, @max(byte_len, min_bitmap_byte_len));
    const real_len = @as(usize, 1) << @intCast(log2_len);

    return real_len;
}
