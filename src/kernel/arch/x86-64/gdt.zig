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
    pub const Access = packed struct {
        accessed: u1 = 0,
        read_write: u1,
        dir_confirm: u1 = 0,
        executable: u1,
        seg_type: u1 = 1,
        privilege_level: u2,
        present: u1 = 1,

        comptime { std.debug.assert(@sizeOf(Access) == 1); }
    };

    pub const Flags = packed struct {
        _reserved: u1 = 0,
        long_mode: u1,
        size: u1,
        granularity: u1,

        comptime { std.debug.assert(@bitSizeOf(Flags) == 4); }
    };

    limit: u16 = 0xFFFF,
    base: u24 = 0,
    access: Access,

    limit_1: u4 = 0xF,
    flags: Flags,
    base_1: u8 = 0,

    comptime { std.debug.assert(@sizeOf(SegmentDescriptor) == 0x8); }
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

pub const kernel_cs: SegmentDescriptor = .{
    .access = .{ .executable = 1, .read_write = 1, .privilege_level = 0 },
    .flags = .{ .long_mode = 1, .size = 0, .granularity = 1 }
};

pub const kernel_ss: SegmentDescriptor = .{
    .access = .{ .executable = 0, .read_write = 1, .privilege_level = 0 },
    .flags = .{ .long_mode = 0, .size = 1, .granularity = 1 }
};

pub const user_cs: SegmentDescriptor = .{
    .access = .{ .executable = 1, .read_write = 1, .privilege_level = 3 },
    .flags = .{ .long_mode = 1, .size = 0, .granularity = 1 }
};

pub const user_ss: SegmentDescriptor = .{
    .access = .{ .executable = 0, .read_write = 1, .privilege_level = 3 },
    .flags = .{ .long_mode = 0, .size = 1, .granularity = 1 }
};

pub const kernel_cs_sel: SegmentSelector = .{
    .index = 1,
    .ti = .gdt,
    .rpl = .kernel,
};

pub const kernel_ss_sel: SegmentSelector = .{
    .index = 2,
    .ti = .gdt,
    .rpl = .kernel
};

pub const user_ss_sel: SegmentSelector = .{
    .index = 3,
    .ti = .gdt,
    .rpl = .userspace
};

pub const user_cs_sel: SegmentSelector = .{
    .index = 4,
    .ti = .gdt,
    .rpl = .userspace
};

var gdt_buffer: [max_entries]SegmentDescriptor = undefined;
var gdt: std.ArrayList(SegmentDescriptor) = .initBuffer(&gdt_buffer);
var tss_base_idx: usize = 0;

pub fn init() void {
    const gdtr = regs.getGdtr();
    const src_gdt_ptr: [*]SegmentDescriptor = @ptrFromInt(vm.getVirtLma(gdtr.base)); 
    const src_gdt_len = gdtr.limit / @sizeOf(SegmentDescriptor);
    const src_gdt = src_gdt_ptr[0..src_gdt_len];

    const null_desc = std.mem.zeroes(SegmentDescriptor);

    gdt.appendAssumeCapacity(null_desc);
    gdt.appendAssumeCapacity(kernel_cs);
    gdt.appendAssumeCapacity(kernel_ss);
    gdt.appendAssumeCapacity(user_ss);
    gdt.appendAssumeCapacity(user_cs);
    gdt.appendSliceAssumeCapacity(src_gdt[gdt.items.len..]);

    tss_base_idx = gdt.items.len;

    // Fill with zeros other entries
    @memset(gdt_buffer[gdt.items.len..], null_desc);
}

pub fn addTss(tss: *const intr.TaskStateSegment) !void {
    const descriptor: *align(8) SystemSegmentDescriptor = @ptrCast(try gdt.addOneBounded());

    _ = try gdt.addOneBounded();

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
        .base = @intFromPtr(&gdt_buffer),
        .limit = @as(u16, @truncate(gdt_buffer.len)) * @sizeOf(SegmentDescriptor) - 1
    });

    asm volatile ("call setupKernelSegments"::: .{ .memory = true });
}

export fn setupKernelSegments() callconv(.naked) noreturn {
    asm volatile (
        \\ push %[ss_sel]
        \\ push %rsp
        \\ addq $0x10,(%rsp) 
        \\ pushfq
        \\ push %[cs_sel]
        \\ push 0x20(%rsp)
        \\ iretq
        :: [ss_sel] "i" (kernel_ss_sel),
           [cs_sel] "i" (kernel_cs_sel)
    );
}
