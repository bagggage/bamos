const std = @import("std");
const builtin = @import("builtin");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86-64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const Bitmap = @import("utils/Bitmap.zig");
pub const List = std.DoublyLinkedList;
pub const SList = std.SinglyLinkedList;
pub const Heap = @import("utils/Heap.zig");

pub const byte_size = 8;
pub const kb_size = 1024;
pub const mb_size = kb_size * 1024;
pub const gb_size = mb_size * 1024;

pub inline fn calcAlign(comptime T: type, value: T, alignment: T) T {
    return ((value + (alignment - 1)) & ~(alignment - 1));
}

pub inline fn halt() noreturn {
    while (true) {}
}