//! # Linux ABI compatible syscalls implementation

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = lib.arch;
const lib = @import("../../lib.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.call.linux");
const trace = std.log.scoped(.@"sys.call.trace");
const sys = @import("../../sys.zig");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const SyscallFn = ?*const fn () callconv(.c) isize;

const table_len = 256;

pub const table = initSyscallTable();

fn initSyscallTable() [table_len]SyscallFn {
    var result: [table_len]SyscallFn = .{ null } ** table_len;

    result[@intFromEnum(linux.SYS.brk)] = @ptrCast(&brk);

    return result;
}

inline fn errorFromE(comptime e: linux.E) isize {
    const code: isize = comptime @intFromEnum(e);
    return -code;
}

fn errorFromZig(e: vfs.Error) isize {
    return switch (e) {
        error.BadDentry,
        error.BadInode       => errorFromE(.BADF),
        error.BadLbaSize,
        error.BadName        => errorFromE(.INVAL),
        error.BadOperation   => errorFromE(.OPNOTSUPP),
        error.BadSuperblock  => errorFromE(.INVAL),
        error.Busy           => errorFromE(.BUSY),
        error.DevMajorLimit  => errorFromE(.BUSY),
        error.DevMinorLimit  => errorFromE(.BUSY),
        error.Exists         => errorFromE(.EXIST),
        error.InvalidArgs    => errorFromE(.INVAL),
        error.IoFailed       => errorFromE(.IO),
        error.MaxSize        => errorFromE(.FBIG),
        error.NoAccess       => errorFromE(.ACCES),
        error.NoEnt          => errorFromE(.NOENT),
        error.NoMemory       => errorFromE(.NOMEM),
        error.SegFault       => errorFromE(.FAULT),
        error.NoFs,
        error.Uninitialized => errorFromE(.NODEV)
    };
}

pub inline fn badCallHandler(id: usize) isize {
    const proc = sys.Process.getCurrent();
    const name = blk: {
        const tag = std.enums.fromInt(linux.SYS, id) orelse break :blk null;
        break :blk @tagName(tag);
    };

    sys.call.badCallHandler(proc, id, name, .{});
    return errorFromE(.NOSYS);
}

fn brk(new_brk: usize) callconv(.c) usize {
    const proc = sys.Process.getCurrent();
    const curr_brk,
    const curr_pages = blk: {
        proc.addr_space.map_lock.readLock();
        defer proc.addr_space.map_lock.readUnlock();

        const heap = proc.addr_space.heap.?;
        break :blk .{ heap.top(), heap.page_capacity };
    };

    trace.info("brk(0x{x}); curr: 0x{x}", .{new_brk, curr_brk});

    if (new_brk > curr_brk) {
        const pages = vm.bytesToPages(new_brk - curr_brk);
        _ = proc.addr_space.heapGrow(pages) orelse return curr_brk;
    } else {
        const pages = vm.bytesToPagesExact(curr_brk - new_brk);
        if (pages == 0) return if (curr_pages > 0) new_brk else curr_brk;
        
        proc.addr_space.heapShrink(pages) catch return curr_brk;
    }

    return new_brk;
}
