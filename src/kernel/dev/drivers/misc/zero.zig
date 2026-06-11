//! # /dev/zero - device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const devfs = vfs.devfs;
const sys = @import("../../../sys.zig");
const vm = @import("../../../vm.zig");
const vfs = @import("../../../vfs.zig");

const dev_file_ops: devfs.DevFile.Operations = .{
    .fops = .{
        .read = &fileRead,
        .write = &fileWrite,
        .mmapPrepare = &fileMmapPrepare,
    }
};

const map_ops: sys.AddressSpace.MapUnit.Operations = .{
    .pageFault = &mapUnitPageFault,
    .unmapPage = &mapUnitUnmapPage,
};

var dev_file: devfs.DevFile = .{
    .name = undefined, // Compiler bug, cannot initialize name at comptime!
    .access = .{ .gid = 0, .perm = @intFromEnum(vfs.Permissions.rw) },
    .num = .{ .major = 1, .minor = 5 },
    .ops = &dev_file_ops,
};

pub fn init() !void {
    dev_file.name = .init("zero");
    try devfs.registerCharDev(&dev_file);
}

fn fileWrite(_: *vfs.File, _: usize, buffer: []const u8) vfs.Error!usize {
    return buffer.len;
}

fn fileRead(_: *const vfs.File, _: usize, buffer: []u8) vfs.Error!usize {
    @memset(buffer, 0);
    return buffer.len;
}

fn fileMmapPrepare(_: *const vfs.File, map_unit: *sys.AddressSpace.MapUnit) vfs.Error!void {
    map_unit.ops = &map_ops;
}

fn mapUnitPageFault(
    map_unit: *sys.AddressSpace.MapUnit,
    pt: *vm.PageTable,
    offset: usize,
    _: vm.FaultCause,
) vfs.Error!*vm.Page {
    const page_offset = vm.bytesToPagesExact(offset);
    const phys = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
    const page: vm.Page = .{
        .base = vm.bytesToPagesExact(phys),
        .dim = .{ .idx = @truncate(page_offset) },
    };
    const new_page = map_unit.attachAndMapPage(
        pt,
        page,
        map_unit.flags.map,
    ) catch return error.NoMemory;

    return new_page;
}

fn mapUnitUnmapPage(_: *const sys.AddressSpace.MapUnit, _: *const vm.PageTable, page: vm.Page) void {
    vm.PageAllocator.free(page.getPhysBase(), page.dim.rank);
}
