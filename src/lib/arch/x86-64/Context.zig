//! # x86-64 context switching

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const regs = @import("regs.zig");

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

pub inline fn init(stack_ptr: usize, ip: usize) Self {
    return bindings.getInstance().arch.context.init(stack_ptr, ip);
}

pub inline fn initUnaligned(stack_ptr: usize, ip: usize) Self {
    return bindings.getInstance().arch.context.initUnaligned(stack_ptr, ip);
}

pub inline fn initWorker(stack_ptr: usize, entry: usize, arg: usize) Self {
    return bindings.getInstance().arch.context.initWorker(stack_ptr, entry, arg);
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
