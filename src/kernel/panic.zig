//! # Panic
//! Includes handling kernel panics and tracing stack frame.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const dbg = @import("dbg-info");

const logger = @import("logger.zig");
const smp = @import("smp.zig");
const text_output = video.text_output;
const utils = @import("utils.zig");
const video = @import("video.zig");
const vm = @import("vm.zig");

/// Represents a symbol (function) from the kernel's debugging information.
const Symbol = struct {
    addr: usize = undefined,
    name: []const u8 = undefined,
};

const CodeDump = struct {
    code: ?[]const u8,

    pub fn init(addr: usize) @This() {
        if (addr == 0) return .{ .code = null };
        return .{ .code = @as([*]const u8, @ptrFromInt(addr))[0..10] };
    }

    pub fn format(self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.code == null) {
            try writer.print("invalid instruction pointer...", .{});
            return;
        }

        for (self.code.?) |byte| { try writer.print("{x:0>2} ", .{byte}); }
    }
};

const StackDump = struct {
    stack: []const usize,

    pub fn init(addr: usize) @This() {
        return .{ .stack = @as([*]const usize, @ptrFromInt(addr))[0..10] };
    }

    pub fn format(self: @This(), _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print(
            "<{s}>" ++ logger.new_line,
            .{if (@intFromPtr(self.stack.ptr) % (@sizeOf(usize) * 2) == 0) "aligned" else "unaligned"}
        );

        for (self.stack, 0..) |entry, i| {
            try writer.print(
                "+0x{x:0>2}: 0x{x:.>16}" ++ logger.new_line,
                .{i * @sizeOf(usize),entry}
            );
        }
    }
};

const tty_config: std.io.tty.Config = .escape_codes;

/// External function to retrieve the debug symbols from the kernel.
/// This function is generating by `debug-maker`, it makes possible to
/// include generated debug information as `@embedFile` into the kernel executable.
extern fn getDebugSyms() *const dbg.Header;

/// Handles a kernel panic by printing a panic message and a stack trace.
/// This function is marked as `noreturn` and will halt the system.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    logger.capture();
    defer logger.release();

    {
        tty_config.setColor(logger.writer, .bright_red) catch {};

        _ = logger.writer.writeAll("[KERNEL PANIC]: ") catch {};
        _ = logger.writer.writeAll(msg) catch {};
        _ = logger.writer.writeAll("\n\r") catch {};

        var it = std.debug.StackIterator.init(
            @returnAddress(),
            @frameAddress()
        );

        trace(&it, &logger.writer);
    }

    utils.halt();
}

/// Handles exception by printing message.
/// Makes stack dump, code dump and stack trace.
/// 
/// - `ip`: instruction pointer to make code dump.
/// - `sp`: stack pointer to make stack dump.
/// - `fp`: frame pointer to make stack trace.
/// - `fmt`: additional message format string.
/// - `args`: argumenets used within formating.
pub fn exception(
    ip: usize,
    sp: usize,
    fp: usize,
    comptime fmt: []const u8,
    args: anytype
) void {
    logger.capture();
    defer logger.release();

    tty_config.setColor(logger.writer, .bright_red) catch return;
    logger.writer.print("<<EXCEPTION>> CPU: {}" ++ logger.new_line, .{smp.getIdx()}) catch return;

    tty_config.setColor(logger.writer, .bright_yellow) catch return;
    logger.writer.print(fmt ++ logger.new_line, args) catch return;
    logger.writer.print(
        logger.new_line ++
        \\code: {}
        \\stack: {}
        ++ logger.new_line
        , .{ CodeDump.init(ip), StackDump.init(sp) }
    ) catch return;

    var stack_it = std.debug.StackIterator.init(null, fp);
    trace(&stack_it, &logger.writer);

    tty_config.setColor(logger.writer, .reset) catch return;
}

/// Traces the stack frames and prints the corresponding function names with offsets.
/// This function is used to provide a detailed trace of the function calls leading up to a panic.
pub fn trace(it: *std.debug.StackIterator, writer: *std.io.AnyWriter) void {
    tty_config.setColor(writer, .bright_yellow) catch return;

    if (comptime builtin.mode == .ReleaseFast) {
        writer.writeAll(
            "Tracing cannot be done in `ReleaseFast` build, use `Debug` or `ReleaseSafe` build." ++ logger.new_line
        ) catch return;
        return;
    }

    writer.writeAll("[TRACE]:" ++ logger.new_line) catch return;

    var i: usize = 1;

    while (it.next()) |ret_addr| : (i += 1) {
        const symbol = addrToSym(ret_addr);
        const sym_name = if (symbol) |sym| sym.name else "<unknown>";
        const addr_offset = if (symbol) |sym| ret_addr - sym.addr else 0;

        writer.print(
            "{:2}. 0x{x:0<16}: {s}+0x{x}" ++ logger.new_line,
            .{ i, ret_addr, sym_name, addr_offset }
        ) catch return;
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
