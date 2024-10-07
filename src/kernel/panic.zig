//! # Panic
//! Includes handling kernel panics and tracing stack frame.

const std = @import("std");
const builtin = @import("std").builtin;
const dbg = @import("dbg-info");

const log = @import("log.zig");
const text_output = video.text_output;
const utils = @import("utils.zig");
const vm = @import("vm.zig");
const video = @import("video.zig");

/// Represents a symbol (function) from the kernel's debugging information.
const Symbol = struct {
    addr: usize = undefined,
    name: []const u8 = undefined,
};

/// Buffer used for formatting stack trace messages.
var fmt_buffer: [256]u8 = undefined;

/// External function to retrieve the debug symbols from the kernel.
/// This function is generating by `debug-maker`, it makes possible to
/// include generated debug information as `@embedFile` into the kernel executable.
extern fn getDebugSyms() *const dbg.Header;

/// Handles a kernel panic by printing a panic message and a stack trace.
/// This function is marked as `noreturn` and will halt the system.
pub fn panic(msg: []const u8, _: ?*builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    if (text_output.isEnabled() == false) text_output.init();

    text_output.setColor(video.Color.red);
    text_output.print("[KERNEL PANIC]: ");
    text_output.setColor(video.Color.lred);
    text_output.print(msg);
    text_output.print("\n");

    var it = std.debug.StackIterator.init(@returnAddress(), @frameAddress());

    trace(&it);

    utils.halt();
}

/// Traces the stack frames and prints the corresponding function names with offsets.
/// This function is used to provide a detailed trace of the function calls leading up to a panic.
pub fn trace(it: *std.debug.StackIterator) void {
    text_output.setColor(video.Color.lyellow);
    text_output.print("[TRACE]:\n");

    var i: usize = 1;

    while (it.next()) |ret_addr| : (i += 1) {
        const symbol = addrToSym(ret_addr);
        const sym_name = if (symbol) |sym| sym.name else "<unknown>";
        const addr_offset = if (symbol) |sym| ret_addr - sym.addr else 0;

        _ = std.fmt.bufPrint(
            &fmt_buffer,
            "{:2}. 0x{x:0<16}: {s}+0x{x}\n\x00",
            .{ i, ret_addr, sym_name, addr_offset }
        ) catch unreachable;

        text_output.print(&fmt_buffer);
    }
}

/// Resolves a memory address to a symbol using the kernel's debugging information.
/// This function searches through the symbol table
/// to find the function or variable corresponding to the given address.
/// 
/// - `addr` The virtual return address.
fn addrToSym(addr: usize) ?Symbol {
    @setRuntimeSafety(false);

    const header = getDebugSyms();
    const entries: [*]const dbg.Entry = @ptrFromInt(@intFromPtr(header) + @sizeOf(dbg.Header));

    const rel_addr = addr - @intFromPtr(vm.kernel_start);

    for (0..header.entries_num) |i| {
        const entry = &entries[i];

        if (rel_addr >= entry.addr and rel_addr < entry.addr + entry.size) {
            const name: [*:0]const u8 = @ptrFromInt(@intFromPtr(header) + header.strtab_offset + entry.name_offset);

            var symbol: Symbol = undefined;

            symbol.addr = entry.addr + @intFromPtr(vm.kernel_start);
            symbol.name = @as([*]const u8, @ptrCast(name))[0..std.mem.len(name)];

            return symbol;
        }
    }

    return null;
}
