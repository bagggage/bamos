const std = @import("std");
const builtin = @import("std").builtin;
const dbg = @import("dbg-info");

const log = @import("log.zig");
const text_output = video.text_output;
const utils = @import("utils.zig");
const vm = @import("vm.zig");
const video = @import("video.zig");

const Symbol = struct {
    addr: usize = undefined,
    name: []const u8 = undefined,

    pub var unknown = Symbol{ .addr = 0 };

    pub inline fn isUnknown(self: Symbol) bool {
        return self.addr == 0;
    }
};

var fmt_buffer: [256]u8 = undefined;

extern fn getDebugSyms() *const dbg.Header;

pub fn panic(msg: []const u8, _: ?*builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    if (text_output.isEnabled() == false) text_output.init();

    text_output.setColor(video.Color.red);
    text_output.print("[KERNEL PANIC]: ");
    text_output.setColor(video.Color.lred);
    text_output.print(msg);

    var it = std.debug.StackIterator.init(@returnAddress(), @frameAddress());

    if (it.next() != null) trace(&it);

    utils.halt();
}

pub fn trace(it: *std.debug.StackIterator) void {
    text_output.setColor(video.Color.lyellow);
    text_output.print("\n[TRACE]:\n");

    while (it.next()) |ret_addr| {
        const symbol = addrToSym(ret_addr);
        const sym_name = if (symbol.isUnknown()) "UNKNOWN" else symbol.name;
        const addr_offset = if (symbol.isUnknown()) 0 else ret_addr - symbol.addr;

        _ = std.fmt.bufPrint(&fmt_buffer, "0x{x}: {s}+0x{x}\n\x00", .{ ret_addr, sym_name, addr_offset }) catch unreachable;

        text_output.print(&fmt_buffer);
    }
}

fn addrToSym(addr: usize) Symbol {
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

    return Symbol.unknown;
}
