//! # x86-64 context switching

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const intr = @import("intr.zig");
const gdt = @import("gdt.zig");
const regs = @import("regs.zig");
const sched = @import("../../sched.zig");

const Self = @This();

const StackPointer = struct {
    ptr: [*]u64,

    pub inline fn asIntrFrame(self: StackPointer) *regs.InterruptFrame {
        @setRuntimeSafety(false);
        return @ptrCast(self.ptr);
    }
};

stack_ptr: StackPointer,

pub fn init(
    self: *Self,
    stack_ptr: usize,
    ip: usize,
    level: sched.PrivilegeLevel
) void {
    self.stack_ptr.ptr = @ptrFromInt(stack_ptr - @sizeOf(regs.InterruptFrame));
    const frame = self.stack_ptr.asIntrFrame();

    var ss = gdt.kernel_ss;
    var cs = gdt.kernel_cs;

    if (level == .userspace) {
        ss.rpl = .userspace;
        cs.rpl = .userspace;
    }

    frame.rsp = stack_ptr;
    frame.rflags = 0;
    frame.rip = ip;
    frame.ss = ss.asInt();
    frame.cs = cs.asInt();
}

pub inline fn setInstrPtr(self: *Self, value: usize) void {
    self.stack_ptr.asIntrFrame().rip = @intFromPtr(value);
}

pub inline fn getInstrPtr(self: *Self) usize {
    return self.stack_ptr.asIntrFrame().rip;
}

pub inline fn setStackPtr(self: *Self, value: usize) void {
    self.stack_ptr.ptr = @ptrFromInt(value);
}

pub inline fn getStackPtr(self: *Self) usize {
    return @intFromPtr(self.stack_ptr.ptr);
}

pub inline fn setPriviligeLevel(self: *Self, level: sched.PrivilegeLevel) void {
    const frame = self.stack_ptr.asIntrFrame();
    const cs: gdt.SegmentSelector = @bitCast(@as(u16, @truncate(frame.cs)));

    cs.rpl = switch (level) {
        .kernel => 0,
        .userspace => 3
    };

    frame.cs = cs.asInt();
}

pub fn jumpTo(self: *Self) noreturn {
    regs.setStack(self.getStackPtr());
    asm volatile("iretq");

    unreachable;
}
