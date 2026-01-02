//! # Linux ABI compatible syscalls implementation

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("opts");

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

    if (comptime builtin.cpu.arch == .x86_64) {
        result[@intFromEnum(linux.SYS.arch_prctl)] = @ptrCast(&archPrCtl);
    }

    result[@intFromEnum(linux.SYS.brk)] = @ptrCast(&brk);
    result[@intFromEnum(linux.SYS.uname)] = @ptrCast(&uname);

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

fn archPrCtl(op: c_int, addr: usize) isize {
    const ARCH_SET_GS = 0x1001;
    const ARCH_SET_FS = 0x1002;
    const ARCH_GET_FS = 0x1003;
    const ARCH_GET_GS = 0x1004;
    const ARCH_GET_CPUID = 0x1011;
    const ARCH_SET_CPUID = 0x1012;
    const ARCH_GET_XCOMP_SUPP = 0x1021;
    const ARCH_GET_XCOMP_PERM = 0x1022;
    const ARCH_REQ_XCOMP_PERM = 0x1023;
    const ARCH_GET_XCOMP_GUEST_PERM = 0x1024;
    const ARCH_REQ_XCOMP_GUEST_PERM = 0x1025;
    const ARCH_XCOMP_TILECFG = 17;
    const ARCH_XCOMP_TILEDATA = 18;
    const ARCH_MAP_VDSO_X32 = 0x2001;
    const ARCH_MAP_VDSO_32 = 0x2002;
    const ARCH_MAP_VDSO_64 = 0x2003;
    const ARCH_GET_UNTAG_MASK = 0x4001;
    const ARCH_ENABLE_TAGGED_ADDR = 0x4002;
    const ARCH_GET_MAX_TAG_BITS = 0x4003;
    const ARCH_FORCE_TAGGED_SVA = 0x4004;
    const ARCH_SHSTK_ENABLE = 0x5001;
    const ARCH_SHSTK_DISABLE = 0x5002;
    const ARCH_SHSTK_LOCK = 0x5003;
    const ARCH_SHSTK_UNLOCK = 0x5004;
    const ARCH_SHSTK_STATUS = 0x5005;

    trace.info("arch_prctl({x}, 0x{x})", .{op, addr});
    const dest: ?*usize = @ptrFromInt(addr);

    switch (op) {
        ARCH_SET_GS => {
            arch.intr.disableForCpu();
            defer arch.intr.enableForCpu();

            arch.regs.swapgs();
            defer arch.regs.swapgs();

            arch.regs.setMsr(arch.regs.MSR_GS_BASE, addr);
        },
        ARCH_SET_FS => arch.regs.setMsr(arch.regs.MSR_FS_BASE, addr),
        ARCH_GET_FS => dest.?.* = arch.regs.getMsr(arch.regs.MSR_FS_BASE),
        ARCH_GET_GS => {
            arch.intr.disableForCpu();
            defer arch.intr.enableForCpu();

            arch.regs.swapgs();
            defer arch.regs.swapgs();

            dest.?.* = arch.regs.getMsr(arch.regs.MSR_GS_BASE);
        },
        ARCH_GET_CPUID,
        ARCH_SET_CPUID,
        ARCH_GET_XCOMP_SUPP,
        ARCH_GET_XCOMP_PERM,
        ARCH_REQ_XCOMP_PERM,
        ARCH_GET_XCOMP_GUEST_PERM,
        ARCH_REQ_XCOMP_GUEST_PERM,
        ARCH_XCOMP_TILECFG,
        ARCH_XCOMP_TILEDATA,
        ARCH_MAP_VDSO_X32,
        ARCH_MAP_VDSO_32,
        ARCH_MAP_VDSO_64,
        ARCH_GET_UNTAG_MASK,
        ARCH_ENABLE_TAGGED_ADDR,
        ARCH_GET_MAX_TAG_BITS,
        ARCH_FORCE_TAGGED_SVA,
        ARCH_SHSTK_ENABLE,
        ARCH_SHSTK_DISABLE,
        ARCH_SHSTK_LOCK,
        ARCH_SHSTK_UNLOCK,
        ARCH_SHSTK_STATUS => return errorFromE(.INVAL),
        else => return errorFromE(.INVAL)
    }

    return 0;
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

fn uname(buf: *linux.utsname) isize {
    trace.info("uname(0x{x})", .{@intFromPtr(buf)});

    if (!vm.isUserVirtAddr(@intFromPtr(buf))) return errorFromE(.FAULT);
    @memset(std.mem.asBytes(buf), 0);

    const sysname = opts.os_name;
    const machine = @tagName(builtin.cpu.arch);
    const version = opts.build;
    const release = opts.version_string;

    @memcpy(buf.sysname[0..sysname.len], sysname);
    @memcpy(buf.version[0..version.len], version);
    @memcpy(buf.release[0..release.len], release);
    @memcpy(buf.machine[0..machine.len], machine);

    return 0;
}
