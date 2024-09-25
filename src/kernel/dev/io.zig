//! # Architecture-independent I/O subsytem

const std = @import("std");
const builtin = @import("builtin");

const log = @import("../log.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub usingnamespace utils.arch.io;

pub const Type = enum(u1) {
    mmio,
    io_ports
};

const Region = packed struct {
    name: [*:0]const u8,
    base: usize,
    end: usize,

    pub fn format(self: *const Region, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}: 0x{x}-0x{x}", .{self.name, self.base, self.end - 1});
    }
};
const RegionList = utils.SList(Region);
const RegionNode = RegionList.Node;

var lock = utils.Spinlock.init(.unlocked);
var region_oma = vm.ObjectAllocator.init(RegionNode);

var ports_list = RegionList{};
var mmio_list = RegionList{};

inline fn getIoList(comptime io_type: Type) *RegionList {
    return switch (io_type) {
        .io_ports => &ports_list,
        .mmio => &mmio_list
    };
}

/// Write byte into mmio memory.
pub inline fn writeb(ptr: *volatile u8, data: u8) void {
    @setRuntimeSafety(false);
    ptr.* = data;
}

/// Write word into mmio memory.
pub inline fn writew(ptr: *volatile u16, data: u16) void {
    @setRuntimeSafety(false);
    ptr.* = std.mem.nativeToLittle(u16, data);
}

/// Write double word into mmio memory.
pub inline fn writel(ptr: *volatile u32, data: u32) void {
    @setRuntimeSafety(false);
    ptr.* = std.mem.nativeToLittle(u32, data);
}

/// Write quad word into mmio memory.
pub inline fn writeq(ptr: *volatile u64, data: u64) void {
    @setRuntimeSafety(false);
    ptr.* = std.mem.nativeToLittle(u16, data);
}

/// Read byte from mmio memory.
pub inline fn readb(ptr: *const volatile u8) u8 {
    @setRuntimeSafety(false);
    return ptr.*;
}

/// Read word from mmio memory.
pub inline fn readw(ptr: *const volatile u16) u16 {
    @setRuntimeSafety(false);
    return std.mem.littleToNative(u16, ptr.*);
}

/// Read double word from mmio memory.
pub inline fn readl(ptr: *const volatile u32) u32 {
    @setRuntimeSafety(false);
    return std.mem.littleToNative(u32, ptr.*);
}

/// Read quad word from mmio memory.
pub inline fn readq(ptr: *const volatile u64) u64 {
    @setRuntimeSafety(false);
    return std.mem.littleToNative(u32, ptr.*);
}

pub fn request(comptime name: [:0]const u8, base: usize, size: usize, comptime io_type: Type) ?usize {
    const end = base + size;

    const list = getIoList(io_type);

    {
        lock.lock();
        defer lock.unlock();

        var temp = list.first;

        while (temp) |node| : (temp = node.next) {
            const region = &node.data;

            if (region.end <= base or region.base >= end) continue;

            return null;
        }

        const new_region = region_oma.alloc(RegionNode) orelse return null;
        new_region.* = RegionNode{
            .data = .{ .base = base, .end = end, .name = name }
        };

        list.prepend(new_region);
    }

    log.debug("{s: <8}: {s: <12} 0x{x}-0x{x}", .{@tagName(io_type), name, base, base + size - 1});

    return base;
}

pub fn release(base: usize, comptime io_type: Type) void {
    const list = getIoList(io_type);

    lock.lock();
    defer lock.unlock();

    var temp = list.first;

    while (temp) |node| : (temp = node.next) {
        const region = &node.data;

        if (region.base == base) {
            list.remove(node);
            region_oma.free(node);
            
            return;
        }
    }

    unreachable;
}

pub fn isAvail(base: usize, size: usize, comptime io_type: Type) bool {
    const end = base + size;

    lock.lock();
    defer lock.unlock();

    var temp = getIoList(io_type).first;

    while (temp) |node| : (temp = node.next) {
        const region = &node.data;

        if (region.end <= base or region.base >= end) continue;

        return false;
    }

    return true;
}