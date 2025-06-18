//! # Thread Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = utils.arch;
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const stack_alignment = @sizeOf(usize);

const kernel_stack_map_flags = vm.MapFlags{
    .global = true,
    .write = true,
};

const user_stack_map_flags = vm.MapFlags{
    .user = true,
    .global = true,
    .write = true,
};

pub const UserThread = struct {
    /// Architechture specific context
    context: arch.Context,

    stack: vm.VirtualRegion,
    kernel_stack: vm.VirtualRegion,
};

pub const KernelThread = struct {
    const STACK_MMAP_FLAGS = vm.MapFlags{
        .global = true,
        .write = true,
    };

    /// Architechture specific context
    context: arch.Context,

    stack: vm.VirtualRegion,
};

pub fn initStack(stack: *vm.VirtualRegion, stack_size: usize) ?usize {
    const pages = std.math.divCeil(usize, stack_size, vm.page_size) catch unreachable;
    const virt = vm.heapReserve(@truncate(pages));

    stack.* = .init(virt);

    // TODO: FIXME!
    // Stack must grow down and starts from top.
    if (stack.grow(1, kernel_stack_map_flags) == false) {
        vm.heapRelease(virt, @truncate(pages));
        return null;
    }

    return stack.getTopAligned(stack_alignment);
}

pub fn deinitStack(stack: *vm.VirtualRegion, stack_size: usize) void {
    const pages = std.math.divCeil(usize, stack_size, vm.page_size) catch unreachable;

    vm.heapRelease(stack.base, @truncate(pages));
    stack.deinit();
}
