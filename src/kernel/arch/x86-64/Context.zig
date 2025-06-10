//! # x86-64 context switching

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

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

const CtxRegs = extern struct {
    callee: regs.CalleeRegs,
    ret_ptr: usize
};

stack_ptr: StackPointer,

pub fn init(
    self: *Self,
    stack_ptr: usize,
    ip: usize,
) void {
    self.setStackPtr(stack_ptr - @sizeOf(CtxRegs));
    const ctx_regs = self.stack_ptr.asCtxRegs();

    ctx_regs.ret_ptr = ip;
    ctx_regs.callee.rbp = self.getStackPtr();
}

pub inline fn setInstrPtr(self: *Self, value: usize) void {
    self.stack_ptr.asCtxRegs().ret_ptr = value;
}

pub inline fn getInstrPtr(self: *Self) usize {
    return self.stack_ptr.asCtxRegs().ret_ptr;
}

pub inline fn setStackPtr(self: *Self, value: usize) void {
    @setRuntimeSafety(false);
    self.stack_ptr.ptr = @ptrFromInt(value);
}

pub inline fn getStackPtr(self: *Self) usize {
    @setRuntimeSafety(false);
    return @intFromPtr(self.stack_ptr.ptr);
}

pub fn jumpTo(self: *Self) noreturn {
    @setRuntimeSafety(false);

    regs.setStack(self.getStackPtr());
    regs.restoreCallerRegs();

    asm volatile("retq");

    unreachable;
}

pub inline fn switchTo(_: *Self, _: *Self) void {
    asm volatile(
        "call switchToEx":::
        "{rax}","{rdi}","{rsi}","{rdx}",
        "{rcx}","{r8}","{r9}","{r10}",
        "{r11}", "memory"
    );
}

export fn switchToEx(_: *Self, _: *Self) callconv(.naked) void {
    regs.saveCallerRegs();

    // Swap stack.
    comptime std.debug.assert(@offsetOf(Self, "stack_ptr") == 0);
    asm volatile(
        \\ mov %rsp, (%rdi)
        \\ mov (%rsi), %rsp
    );

    regs.restoreCallerRegs();
    asm volatile("retq");
}
