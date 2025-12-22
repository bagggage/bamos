//! # x86-64 context switching

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../../lib.zig");
const intr = @import("intr.zig");
const gdt = @import("gdt.zig");
const regs = @import("regs.zig");
const sched = @import("../../sched.zig");

const Self = @This();

const StackPointer = struct {
    ptr: [*]u64,

    pub inline fn asCtxRegs(self: StackPointer) *CtxRegs {
        @setRuntimeSafety(false);
        return @ptrCast(self.ptr);
    }
};

const CtxRegs = extern struct { callee: regs.CalleeRegs, ret_ptr: usize };

stack_ptr: StackPointer,

pub fn init(stack_ptr: usize, ip: usize) Self {
    comptime std.debug.assert(!std.mem.isAligned(@sizeOf(CtxRegs), 16));

    const ptr = lib.misc.alignDown(usize, stack_ptr - @sizeOf(CtxRegs), 16);
    const ctx_regs: *CtxRegs = @ptrFromInt(ptr);

    ctx_regs.* = .{
        .callee = .{ .rbp = ptr + @offsetOf(regs.CalleeRegs, "rbp") },
        .ret_ptr = ip
    };

    return .{ .stack_ptr = .{ .ptr = @ptrFromInt(ptr) } };
}

pub inline fn setInstrPtr(self: *Self, value: usize) void {
    self.stack_ptr.asCtxRegs().ret_ptr = value;
}

pub inline fn getInstrPtr(self: *Self) usize {
    return self.stack_ptr.asCtxRegs().ret_ptr;
}

pub inline fn setFramePtr(self: *Self, value: usize) void {
    @setRuntimeSafety(false);
    self.stack_ptr.ptr = @ptrFromInt(value);
}

pub inline fn getFramePtr(self: *Self) usize {
    @setRuntimeSafety(false);
    return @intFromPtr(self.stack_ptr.ptr);
}

pub fn jumpTo(self: *Self) noreturn {
    @setRuntimeSafety(false);

    regs.setStack(self.getFramePtr());
    regs.restoreCallerRegs();

    asm volatile ("retq");
    unreachable;
}

pub inline fn switchTo(from: *Self, to: *Self) void {
    asm volatile ("call switchToEx"
        :
        : [arg1] "{rdi}" (from),
          [arg2] "{rsi}" (to),
        : .{
            .rax = true, .rdi = true, .rsi = true, .rdx = true,
            .rcx = true, .r8 = true, .r9 = true, .r10 = true,
            .r11 = true, .memory = true
        }
    );
}

export fn switchToEx(_: *Self, _: *Self) callconv(.naked) void {
    defer asm volatile ("retq");

    regs.saveCallerRegs();
    defer regs.restoreCallerRegs();

    // Swap stack.
    comptime std.debug.assert(@offsetOf(Self, "stack_ptr") == 0);
    asm volatile (
        \\ mov %rsp, (%rdi)
        \\ mov (%rsi), %rsp
        \\ mov %rsp, %rbp
        \\ and $-16, %rsp
        \\ call switchEndEx
        \\ mov %rbp, %rsp
        ::: .{ .memory = true }
    );
}
