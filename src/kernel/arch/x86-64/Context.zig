//! # x86-64 context switching

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

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

pub fn jumpInto(self: *Self, new_task: ?*sched.Task) noreturn {
    @setRuntimeSafety(false);
    self.run();

    const scheduler = sched.getCurrent();
    scheduler.completeSwitch(new_task);

    self.restore();
    asm volatile ("retq");

    unreachable;
}

pub inline fn switchTo(from: *Self, to: *Self) void {
    asm volatile ("call switchToNaked"
        :: [arg1] "{rdi}" (from), [arg2] "{rsi}" (to),
        : regs.call_clobers
    );
}

pub inline fn switchToHalf(from: *Self, to: *Self) void {
    from.save();
    to.run();
}

export fn switchToNaked() callconv(.naked) void {
    const from: *Self = asm volatile("" : [arg1] "={rdi}" (-> *Self));
    const to: *Self = asm volatile("" : [arg2] "={rsi}" (-> *Self));

    comptime @export(&sched.Scheduler.postSwitch, .{ .name = "sched.Scheduler.postSwitch" });

    from.switchToHalf(to);

    const scheduler = sched.getCurrent();
    asm volatile ("call sched.Scheduler.postSwitch"
        :: [arg1] "{rdi}" (scheduler), [arg2] "{rsi}" (to)
        : regs.call_clobers
    );

    to.restore();
    asm volatile ("retq");
}

inline fn run(self: *Self) void {
    asm volatile (
        "mov (%[rsp]), %rsp"
        :: [rsp] "r" (&self.stack_ptr.ptr)
    );
}

inline fn save(self: *Self) void {
    regs.saveCallerRegs();
    asm volatile (
        "mov %rsp, (%[rsp])"
        :: [rsp] "r" (&self.stack_ptr)
        : .{ .memory = true }
    );
}

inline fn restore(_: *Self) void {
    regs.restoreCallerRegs();
}

