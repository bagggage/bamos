const std = @import("std");

const arch = @import("arch.zig");
const boot = @import("../../boot.zig");
const regs = @import("regs.zig");
const intr = @import("intr.zig");
const vm = @import("../../vm.zig");

pub const max_entries = 256;

pub const SegmentSelector = packed struct {
    /// Privilege Level.
    rpl: enum(u2) {
        kernel = 0,
        userspace = 3,
    },

    /// Specifies which descriptor table to useSpecifies which descriptor table to use.
    /// 0 - GDT; 1 - LDT. 
    ti: enum(u1) {
        gdt = 0,
        ldt = 1
    },

    /// Entry index within the table.
    index: u13,

    pub inline fn asInt(self: SegmentSelector) u16 {
        return @bitCast(self);
    }
};

pub const SegmentDescriptor = packed struct {
    limit: u16,
    base: u24,
    access: u8,

    limit_1: u4,
    flags: u4,
    base_1: u8,

    comptime {
        std.debug.assert(@sizeOf(SegmentDescriptor) == 0x8);
    }
};

pub const SystemSegmentDescriptor = packed struct {
    limit: u16,
    base: u24,
    access: u8,

    limit_1: u4,
    flags: u4,
    base_1: u8,
    base_2: u32,

    rsrved: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(SystemSegmentDescriptor) == 0x10);
    }

    pub fn init(base: u64, limit: u20, access: u8, flags: u4) SystemSegmentDescriptor {
        return .{
            .base = @truncate(base),
            .base_1 = @truncate(base >> 24),
            .base_2 = @truncate(base >> 32),
            .limit = @truncate(limit),
            .limit_1 = @truncate(limit >> 16),
            .access = access,
            .flags = flags
        };
    }
};

pub const kernel_cs: SegmentSelector = .{
    .index = 7,
    .ti = .gdt,
    .rpl = .kernel,
};

pub const kernel_ss: SegmentSelector = .{
    .index = 6,
    .ti = .gdt,
    .rpl = .kernel
};

var gdt = std.BoundedArray(SegmentDescriptor, max_entries).init(0) catch unreachable;
var tss_base_idx: usize = 0;

pub fn init() void {
    const gdtr = regs.getGdtr();

    const gdt_ptr: [*]SegmentDescriptor = @ptrFromInt(vm.getVirtLma(gdtr.base)); 
    const gdt_len = gdtr.limit / @sizeOf(SegmentDescriptor);
    const src_gdt = gdt_ptr[0..gdt_len];

    tss_base_idx = src_gdt.len;

    // Copy first entries
    for (src_gdt) |segment| {
        gdt.append(segment) catch unreachable;
    }

    // Fill with zeros other entries
    @memset(gdt.buffer[src_gdt.len..], std.mem.zeroes(SegmentDescriptor));
}

pub fn addTss(tss: *const intr.TaskStateSegment) !void {
    const descriptor: *align(8) SystemSegmentDescriptor = @ptrCast(try gdt.addOne());

    _ = try gdt.addOne();

    descriptor.* = SystemSegmentDescriptor.init(
        @intFromPtr(tss),
        @sizeOf(intr.TaskStateSegment),
        0x89,
        0x0
    );
}

pub inline fn getTssOffset(idx: u16) u16 {
    return @truncate((tss_base_idx * @sizeOf(SegmentDescriptor)) + (idx * @sizeOf(SystemSegmentDescriptor)));
}

pub inline fn setupCpu() void {
    regs.setGdtr(.{
        .base = @intFromPtr(&gdt.buffer),
        .limit = @as(u16, gdt.buffer.len) * @sizeOf(SegmentDescriptor)
    });
}