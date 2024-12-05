//! # Panic
//! Includes handling kernel panics and tracing stack frame.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const dbg = @import("dbg-info");

const logger = @import("logger.zig");
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

const tty_config: std.io.tty.Config = .escape_codes;

/// External function to retrieve the debug symbols from the kernel.
/// This function is generating by `debug-maker`, it makes possible to
/// include generated debug information as `@embedFile` into the kernel executable.
extern fn getDebugSyms() *const dbg.Header;

/// Handles a kernel panic by printing a panic message and a stack trace.
/// This function is marked as `noreturn` and will halt the system.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    tty_config.setColor(logger.writer, .bright_red) catch {};

    _ = logger.writer.writeAll("[KERNEL PANIC]: ") catch {};
    _ = logger.writer.writeAll(msg) catch {};
    _ = logger.writer.writeAll("\n\r") catch {};

    var it = std.debug.StackIterator.init(@returnAddress(), @frameAddress());

    trace(&it);

    utils.halt();
}

/// Traces the stack frames and prints the corresponding function names with offsets.
/// This function is used to provide a detailed trace of the function calls leading up to a panic.
pub fn trace(it: *std.debug.StackIterator) void {
    tty_config.setColor(logger.writer, .bright_yellow) catch {};

    if (comptime builtin.mode == .ReleaseFast) {
        logger.writer.writeAll("Tracing cannot be done in `ReleaseFast` build, use `Debug` or `ReleaseSafe` build.") catch {};
        return;
    }

    logger.writer.writeAll("[TRACE]:\n\r") catch {};

    var i: usize = 1;

    while (it.next()) |ret_addr| : (i += 1) {
        const symbol = addrToSym(ret_addr);
        const sym_name = if (symbol) |sym| sym.name else "<unknown>";
        const addr_offset = if (symbol) |sym| ret_addr - sym.addr else 0;

        const msg= std.fmt.bufPrint(
            &fmt_buffer,
            "{:2}. 0x{x:0<16}: {s}+0x{x}\n\r\x00",
            .{ i, ret_addr, sym_name, addr_offset }
        ) catch unreachable;

        logger.writer.writeAll(msg) catch {};
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
