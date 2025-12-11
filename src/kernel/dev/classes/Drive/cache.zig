//! # Block device cache helpers

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const Drive = @import("../Drive.zig");
const log = std.log.scoped(.@"Drive.cache");
const vm = @import("../../../vm.zig");

pub const block_size = vm.cache.Block.Size.small_size;

pub const Cursor = struct {
    const blank_offset = std.math.maxInt(usize);

    /// If cursor is blank - `*Drive`, otherwise `*vm.cache.Block`
    accessor: *align(@alignOf(usize)) anyopaque,
    offset: usize = blank_offset,

    pub inline fn blank(drive: *Drive) Cursor {
        return .{ .accessor = @ptrCast(drive) };
    }

    pub fn open(drive: *Drive, comptime op: ?Drive.io.Operation, offset: usize) Drive.Error!Cursor {
        const block = try getOrReadBlock(drive, vm.cache.offsetToIdx(offset));
        if (op) |o| switch (o) { .read => block.readDown(), .write => block.writeDown() };

        return .{ .accessor = @ptrCast(block), .offset = offset };
    }

    pub fn close(self: *Cursor, comptime op: ?Drive.io.Operation) void {
        if (self.isBlank()) return;

        self.unlock(op);
        self.getBlock().deref();
    }

    pub fn ensureCache(self: *Cursor, comptime op: ?Drive.io.Operation, offset: usize) Drive.Error!void {
        const idx = vm.cache.offsetToIdx(offset);
        if (self.isBlank()) {
            defer self.lock(op);

            const drive: *Drive = @ptrCast(self.accessor);
            const block = try getOrReadBlock(drive, idx);
            self.accessor = @ptrCast(block);
        } else if (self.getBlock().index != vm.cache.offsetToIdx(offset)) {
            self.unlock(op);
            defer self.lock(op);

            const block = try getOrReadSwapBlock(self.getBlock(), idx);
            self.accessor = @ptrCast(block);
        }

        self.offset = offset;
    }

    pub fn next(self: *Cursor, comptime op: ?Drive.io.Operation) Drive.Error!void {
        self.unlock(op);
        defer self.lock(op);

        const new_offset = self.getBlock().getOffset() + block_size;
        const block = try getOrReadSwapBlock(self.getBlock(), new_offset);
        self.accessor = @ptrCast(block);
        self.offset = new_offset;
    }

    pub fn read(self: *Cursor, size: usize) Drive.Error![]const u8 {
        try self.ensureCache(.read, self.offset);
        defer self.offset += size;

        return self.asSlice()[0..size];
    }

    pub fn readAs(self: *Cursor, comptime T: type) Drive.Error!*const T {
        try self.ensureCache(.read, self.offset);
        defer self.offset += @sizeOf(T);

        return self.asObject(T);
    }

    pub inline fn seekAndEnsure(self: *Cursor, comptime op: ?Drive.io.Operation, relative_offset: isize) Drive.Error!void {
        const new_offset: usize = @intCast(@as(isize, @intCast(self.offset)) + relative_offset);
        try self.ensureCache(op, new_offset);
    }

    pub fn asSlice(self: *const Cursor) []u8 {
        const inner_offset = self.getBlock().innerOffset(self.offset);
        return self.getBlock().asSlice()[inner_offset..];
    }

    pub fn asObject(self: *const Cursor, comptime T: type) *T {
        const inner_offset = self.getBlock().innerOffset(self.offset);
        return @ptrFromInt(self.getBlock().getAddress() + inner_offset);
    }

    pub inline fn lock(self: *Cursor, comptime op: ?Drive.io.Operation) void {
        if (comptime op == null) return;
        switch (op.?) {
            .read => self.getBlock().readDown(),
            .write => self.getBlock().writeDown()
        }
    }

    pub inline fn unlock(self: *Cursor, comptime op: ?Drive.io.Operation) void {
        if (comptime op == null) return;
        switch (op.?) {
            .read => self.getBlock().readUp(),
            .write => self.getBlock().writeUp()
        }
    }

    pub inline fn isBlank(self: *const Cursor) bool {
        return self.offset == blank_offset;
    }

    pub inline fn innerOffset(self: *const Cursor) usize {
        return self.getBlock().innerOffset(self.offset);
    }

    inline fn getBlock(self: *const Cursor) *vm.cache.Block {
        return @ptrCast(self.accessor);
    }
};

fn getOrReadSwapBlock(block: *vm.cache.Block, index: usize) Drive.Error!*vm.cache.Block {
    const drive: *Drive = @fieldParentPtr("cache_ctrl", block.ctrl);
    const new_block = try getOrReadBlock(drive, index);

    block.deref();
    return new_block;
}

fn getOrReadBlock(drive: *Drive, index: usize) Drive.Error!*vm.cache.Block {
    return vm.cache.getOrNull(&drive.cache_ctrl, index) orelse {
        const offset = vm.cache.idxToOffset(index);
        const new_block = try vm.cache.createBlock(&drive.cache_ctrl, index, .small);
        errdefer new_block.free();

        const lba_offset = drive.offsetToLba(offset);
        try drive.ioSync(.read, lba_offset, new_block.asSlice());

        return vm.cache.insertBlockOrFree(new_block) orelse return new_block;
    };
}
