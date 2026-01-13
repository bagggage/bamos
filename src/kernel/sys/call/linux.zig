//! # Linux ABI compatible syscalls implementation

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("opts");

const arch = lib.arch;
const lib = @import("../../lib.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.call.linux");
const posix = std.posix;
const sched = @import("../../sched.zig");
const sys = @import("../../sys.zig");
const trace = std.log.scoped(.@"sys.call.trace");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const SyscallFn = ?*const fn () callconv(.c) isize;

const table_len = 312;

pub const table = initSyscallTable();

fn initSyscallTable() [table_len]SyscallFn {
    var result: [table_len]SyscallFn = .{ null } ** table_len;

    if (comptime builtin.cpu.arch == .x86_64) {
        result[@intFromEnum(linux.SYS.arch_prctl)] = @ptrCast(&archPrCtl);
    }

    result[@intFromEnum(linux.SYS.brk)] = @ptrCast(&brk);
    result[@intFromEnum(linux.SYS.mmap)] = @ptrCast(&mmap);
    result[@intFromEnum(linux.SYS.open)] = @ptrCast(&open);
    result[@intFromEnum(linux.SYS.pread64)] = @ptrCast(&pread);
    result[@intFromEnum(linux.SYS.preadv)] = @ptrCast(&preadv);
    result[@intFromEnum(linux.SYS.pwrite64)] = @ptrCast(&pwrite);
    result[@intFromEnum(linux.SYS.pwritev)] = @ptrCast(&pwritev);
    result[@intFromEnum(linux.SYS.read)] = @ptrCast(&read);
    result[@intFromEnum(linux.SYS.readv)] = @ptrCast(&readv);
    result[@intFromEnum(linux.SYS.set_tid_address)] = @ptrCast(&setTidAddress);
    result[@intFromEnum(linux.SYS.uname)] = @ptrCast(&uname);
    result[@intFromEnum(linux.SYS.write)] = @ptrCast(&write);
    result[@intFromEnum(linux.SYS.writev)] = @ptrCast(&writev);

    return result;
}

inline fn errorFromE(comptime e: linux.E) isize {
    trace.info("return error: {t}", .{e});
    const code: isize = comptime @intFromEnum(e);
    return -code;
}

fn errorFromZig(e: vfs.Error) isize {
    return switch (e) {
        error.BadDentry,
        error.BadInode,
        error.BadFileDescriptor => errorFromE(.BADF),
        error.BadLbaSize,
        error.BadName           => errorFromE(.INVAL),
        error.BadOperation      => errorFromE(.OPNOTSUPP),
        error.BadSuperblock     => errorFromE(.INVAL),
        error.Busy              => errorFromE(.BUSY),
        error.DevMajorLimit     => errorFromE(.BUSY),
        error.DevMinorLimit     => errorFromE(.BUSY),
        error.Exists            => errorFromE(.EXIST),
        error.InvalidArgs       => errorFromE(.INVAL),
        error.IoFailed          => errorFromE(.IO),
        error.MaxSize           => errorFromE(.FBIG),
        error.NoAccess          => errorFromE(.ACCES),
        error.NoEnt             => errorFromE(.NOENT),
        error.NoMemory          => errorFromE(.NOMEM),
        error.SegFault          => errorFromE(.FAULT),
        error.NoFs,
        error.Uninitialized     => errorFromE(.NODEV)
    };
}

inline fn validateMemoryArgs(base: usize, len: usize) vm.Error!void {
    if (!vm.isUserVirtAddr(base) or !vm.isUserVirtAddr(base +| len)) {
        return error.SegFault;
    }
}

inline fn validateFileMemoryArgs(fd: linux.fd_t, base: usize, len: usize) vfs.Error!void {
    if (fd < 0) return error.BadFileDescriptor;
    try validateMemoryArgs(base, len);
}

pub inline fn badCallHandler(id: usize) isize {
    const proc = sys.Process.getCurrent();
    const tag = std.enums.fromInt(linux.SYS, id);
    const name = if (tag) |t| @tagName(t) else null;

    sys.call.badCallHandler(proc, id, name, .{});
    if (tag == linux.SYS.exit) sched.pause();

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

    validateMemoryArgs(addr, @sizeOf(usize)) catch return errorFromE(.FAULT);
    const dest: ?*usize = @ptrFromInt(addr);

    switch (op) {
        ARCH_SET_GS => arch.regs.setMsr(arch.regs.MSR_SWAPGS_BASE, addr),
        ARCH_SET_FS => arch.regs.setMsr(arch.regs.MSR_FS_BASE, addr),
        ARCH_GET_FS => dest.?.* = arch.regs.getMsr(arch.regs.MSR_FS_BASE),
        ARCH_GET_GS => dest.?.* = arch.regs.getMsr(arch.regs.MSR_SWAPGS_BASE),
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

fn mmap(virt: usize, len: usize, prot: c_int, flags: linux.MAP, fd: linux.fd_t, offset: linux.off_t) usize {
    trace.info("mmap(0x{x}, 0x{x}, {}, {any}, {}, {});", .{virt, len, prot, flags, fd, offset});

    if (!std.mem.isAligned(virt, vm.page_size) or
        !vm.isUserVirtAddr(virt +| len) or
        @intFromEnum(flags.TYPE) == 0 or
        flags.NONBLOCK or flags.POPULATE or flags.LOCKED or
        flags.SYNC or flags.DENYWRITE or len == 0 or
        (flags.FIXED and flags.FIXED_NOREPLACE) or
        (flags.ANONYMOUS and offset != 0)
    ) return @bitCast(errorFromE(.INVAL));

    const mmap_flags: sys.AddressSpace.MapUnit.Flags = .{
        .grow_down = flags.GROWSDOWN,
        .shared = flags.TYPE != .PRIVATE,
        .map = .{
            .none = (prot == linux.PROT.NONE),
            .exec = (prot & linux.PROT.EXEC) != 0,
            .write = (prot & linux.PROT.WRITE) != 0,
            .user = true,
        }
    };

    const proc = sys.Process.getCurrent();
    const file = if (!flags.ANONYMOUS) {
        return @bitCast(errorFromE(.BADF));
    } else null;

    const map_unit = sys.AddressSpace.MapUnit.new(
        file, virt,
        vm.bytesToPagesExact(@intCast(offset)),
        vm.bytesToPages(len), mmap_flags
    ) catch |err| return @bitCast(errorFromZig(err));

    _ = blk: {
        if (flags.FIXED_NOREPLACE) {
            break :blk proc.addr_space.map(map_unit);
        } else if (flags.FIXED) {
            break :blk proc.addr_space.mapReplace(map_unit);
        } else if (virt == 0) {
            break :blk proc.addr_space.mapAnyAddress(map_unit);
        } else {
            break :blk proc.addr_space.mapOrRebase(map_unit);
        }
    } catch |err| {
        map_unit.delete(undefined);
        return @bitCast(errorFromZig(err));
    };

    return map_unit.base();
}

fn open(path: [*c]const u8, flags: linux.O, mode: linux.mode_t) isize {
    trace.info("open(0x{x}, {any}, 0x{x})", .{@intFromPtr(path), flags, mode});

    if (!vm.isUserVirtAddr(@intFromPtr(path))) return @intCast(errorFromE(.FAULT));

    const proc = sys.Process.getCurrent();
    if (proc.files.isFull()) return @intCast(errorFromE(.MFILE));

    const path_slice = path[0..std.mem.len(path)];
    const dentry = vfs.lookup(
        proc.root_dir, proc.work_dir, path_slice
    ) catch |err| return @intCast(errorFromZig(err));
    defer dentry.deref();

    const inode = dentry.inode;
    if (inode.type == .directory and (flags.ACCMODE != .RDONLY or !flags.DIRECTORY)) return @intCast(errorFromE(.ISDIR));
    if (inode.type != .directory and flags.DIRECTORY) return @intCast(errorFromE(.NOTDIR));

    const role = inode.getRole(proc.uid, proc.gid);
    const perm: vfs.Permissions = switch (flags.ACCMODE) {
        .RDONLY => .r,
        .WRONLY => .w,
        .RDWR => .rw,
    };

    if (!inode.checkAccess(perm, role)) return @intCast(errorFromE(.ACCES));
    const desc = proc.files.open(dentry, perm) catch |err| {
        if (err == error.MaxSize) return @bitCast(errorFromE(.NFILE));
        return @bitCast(errorFromZig(err));
    };

    return @intCast(desc.idx);
}

fn pread(fd: linux.fd_t, buf: [*]u8, len: usize, off_l: u32, off_h: u32) isize {
    const offset: u64 = @as(u64, off_l) | (@as(u64, off_h) << @bitSizeOf(u32));
    trace.info("pread({}, 0x{x}, {}, {})", .{fd, @intFromPtr(buf), len, offset});

    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const readed = file.readAt(offset, buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(readed);
}

fn preadv(fd: linux.fd_t, iov: [*]posix.iovec, num: c_int, off_l: u32, off_h: u32) isize {
    var offset: u64 = @as(u64, off_l) | (@as(u64, off_h) << @bitSizeOf(u32));
    trace.info("preadv({}, 0x{x}, {}, {})", .{fd, @intFromPtr(iov), num, offset});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var readed: usize = 0;
    for (iov[0..@intCast(num)]) |*io| {
        validateMemoryArgs(@intFromPtr(io.base), io.len) catch return errorFromE(.FAULT);
        readed += file.readAt(offset, io.base[0..io.len]) catch |err| return errorFromZig(err);
        offset += io.len;
    }

    return @intCast(readed);
}

fn pwrite(fd: linux.fd_t, buf: [*]const u8, len: usize, off_l: u32, off_h: u32) isize {
    const offset: u64 = @as(u64, off_l) | (@as(u64, off_h) << @bitSizeOf(u32));
    trace.info("pwrite({}, 0x{x}, {}, {})", .{fd, @intFromPtr(buf), len, offset});

    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const writen = file.writeAt(offset, buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(writen);
}

fn pwritev(fd: linux.fd_t, iov: [*]posix.iovec_const, num: c_int, off_l: u32, off_h: u32) isize {
    var offset: u64 = @as(u64, off_l) | (@as(u64, off_h) << @bitSizeOf(u32));
    trace.info("pwritev({}, 0x{x}, {}, {})", .{fd, @intFromPtr(iov), num, offset});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec_const))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var writen: usize = 0;
    for (iov[0..@intCast(num)]) |*io| {
        validateMemoryArgs(@intFromPtr(io.base), io.len) catch return errorFromE(.FAULT);
        writen += file.writeAt(offset, io.base[0..io.len]) catch |err| return errorFromZig(err);
        offset += io.len;
    }

    return @intCast(writen);
}

fn read(fd: linux.fd_t, buf: [*]u8, len: usize) isize {
    trace.info("read({}, 0x{x}, {})", .{fd, @intFromPtr(buf), len});
    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const readed = file.read(buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(readed);
}

fn readv(fd: linux.fd_t, iov: [*]posix.iovec, num: c_int) isize {
    trace.info("readv({}, 0x{x}, {})", .{fd, @intFromPtr(iov), num});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var readed: usize = 0;
    for (iov[0..@intCast(num)]) |*io| {
        validateMemoryArgs(@intFromPtr(io.base), io.len) catch return errorFromE(.FAULT);
        readed += file.read(io.base[0..io.len]) catch |err| return errorFromZig(err);
    }

    return @intCast(readed);
}

fn setTidAddress(addr: usize) sys.Process.Pid {
    trace.info("set_tid_address(0x{x})", .{addr});
    log.warn("{t} is not yet implemented", .{linux.SYS.set_tid_address});

    return sys.Process.getCurrent().pid;
}

fn uname(buf: *linux.utsname) isize {
    trace.info("uname(0x{x})", .{@intFromPtr(buf)});

    validateMemoryArgs(@intFromPtr(buf), @sizeOf(linux.utsname)) catch return errorFromE(.FAULT);
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

fn write(fd: linux.fd_t, buf: [*]const u8, len: usize) isize {
    trace.info("write({}, 0x{x}, {})", .{fd, @intFromPtr(buf), len});
    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const writen = file.write(buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(writen);
}

fn writev(fd: linux.fd_t, iov: [*]posix.iovec_const, num: c_int) isize {
    trace.info("writev({}, 0x{x}, {})", .{fd, @intFromPtr(iov), num});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec_const))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var writen: usize = 0;
    for (iov[0..@intCast(num)]) |*io| {
        validateMemoryArgs(@intFromPtr(io.base), io.len) catch return errorFromE(.FAULT);
        writen += file.write(io.base[0..io.len]) catch |err| return errorFromZig(err);
    }

    return @intCast(writen);
}
