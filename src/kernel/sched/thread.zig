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
    .write = true,
};

pub fn initStack(stack: *vm.VirtualRegion, stack_size: usize) ?usize {
    const pages = std.math.divCeil(usize, stack_size, vm.page_size) catch unreachable;
    const rank = std.math.log2_int_ceil(usize, pages) - 1;
    const virt = vm.heapReserve(@truncate(pages));
    const top = virt + (pages * vm.page_size);

    stack.* = .init(top);

    stack.growDown(rank, kernel_stack_map_flags) catch {
        vm.heapRelease(virt, @truncate(pages));
        return null;
    };

    return stack.getTopAligned(stack_alignment);
}

pub fn deinitStack(stack: *vm.VirtualRegion, stack_size: usize) void {
    const pages = std.math.divCeil(usize, stack_size, vm.page_size) catch unreachable;

    vm.heapRelease(stack.base, @truncate(pages));
    stack.deinit(true);
}
