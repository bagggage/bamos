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
const smp = @import("../../smp.zig");
const sys = @import("../../sys.zig");
const trace = std.log.scoped(.@"sys.call.trace");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const SyscallFn = ?*const fn () callconv(.c) isize;

const table_len = 336;

pub const table: [table_len]SyscallFn = blk: {
    var result: [table_len]SyscallFn = .{ null } ** table_len;

    if (builtin.cpu.arch == .x86_64) {
        result[@intFromEnum(linux.SYS.arch_prctl)] = @ptrCast(&archPrCtl);
    }

    result[@intFromEnum(linux.SYS.brk)]             = @ptrCast(&brk);
    result[@intFromEnum(linux.SYS.clock_gettime)]   = @ptrCast(&clockGetTime);
    result[@intFromEnum(linux.SYS.fstat)]           = @ptrCast(&fstat);
    result[@intFromEnum(linux.SYS.fstatat64)]       = @ptrCast(&fstatAt);
    result[@intFromEnum(linux.SYS.get_robust_list)] = @ptrCast(&getRobustList);
    result[@intFromEnum(linux.SYS.getcwd)]          = @ptrCast(&getCwd);
    result[@intFromEnum(linux.SYS.getegid)]         = @ptrCast(&getEgid);
    result[@intFromEnum(linux.SYS.geteuid)]         = @ptrCast(&getEuid);
    result[@intFromEnum(linux.SYS.getgid)]          = @ptrCast(&getGid);
    result[@intFromEnum(linux.SYS.getpid)]          = @ptrCast(&getPid);
    result[@intFromEnum(linux.SYS.getppid)]         = @ptrCast(&getParentPid);
    result[@intFromEnum(linux.SYS.getrandom)]       = @ptrCast(&getRandom);
    result[@intFromEnum(linux.SYS.gettid)]          = @ptrCast(&getTid);
    result[@intFromEnum(linux.SYS.getuid)]          = @ptrCast(&getUid);
    result[@intFromEnum(linux.SYS.ioctl)]           = @ptrCast(&ioctl);
    result[@intFromEnum(linux.SYS.mmap)]            = @ptrCast(&mmap);
    result[@intFromEnum(linux.SYS.mprotect)]        = @ptrCast(&mprotect);
    result[@intFromEnum(linux.SYS.open)]            = @ptrCast(&open);
    result[@intFromEnum(linux.SYS.pread64)]         = @ptrCast(&pread);
    result[@intFromEnum(linux.SYS.preadv)]          = @ptrCast(&preadv);
    result[@intFromEnum(linux.SYS.prlimit64)]       = @ptrCast(&prlimit64);
    result[@intFromEnum(linux.SYS.pwrite64)]        = @ptrCast(&pwrite);
    result[@intFromEnum(linux.SYS.pwritev)]         = @ptrCast(&pwritev);
    result[@intFromEnum(linux.SYS.read)]            = @ptrCast(&read);
    result[@intFromEnum(linux.SYS.readv)]           = @ptrCast(&readv);
    result[@intFromEnum(linux.SYS.rseq)]            = @ptrCast(&rseq);
    result[@intFromEnum(linux.SYS.set_robust_list)] = @ptrCast(&setRobustList);
    result[@intFromEnum(linux.SYS.set_tid_address)] = @ptrCast(&setTidAddress);
    result[@intFromEnum(linux.SYS.stat)]            = @ptrCast(&stat);
    result[@intFromEnum(linux.SYS.time)]            = @ptrCast(&time);
    result[@intFromEnum(linux.SYS.uname)]           = @ptrCast(&uname);
    result[@intFromEnum(linux.SYS.write)]           = @ptrCast(&write);
    result[@intFromEnum(linux.SYS.writev)]          = @ptrCast(&writev);

    break :blk result;
};

pub const AbiData = struct {
    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 128,
    };

    arch_specific: arch.syscall.LinuxAbi = .{},

    robust_list: ?*RobustList.Head = null,
    rseq: ?*RestartableSequence = null,
    rseq_sig: u32 = 0
};

/// Source: https://elixir.bootlin.com/linux/v6.18.6/source/include/uapi/linux/futex.h#L117
const RobustList = extern struct {
    const Head = extern struct {
        list: RobustList,
        futext_offset: c_long,
        list_op_pending: ?*RobustList,
    };

    next: ?*RobustList = null,
};

const RestartableSequence = extern struct {
    const CriticalSection = extern struct {
        const Flags = enum(u32) {
            no_restart_on_preempt = 0b001,
            no_restart_on_signal  = 0b010,
            no_restart_on_migrate = 0b100,
            _
        };

        version: u32 align(32),
        flags: Flags,
        start_ip: u64,
        post_commit_offset: u64,
        abort_ip: u64,
    };

    const CallFlags = enum(u32) {
        none = 0,
        unregister = 1,
        _
    };

    const cpu_id_uninitialized: u32       = @bitCast(-1);
    const cpu_id_registration_failed: u32 = @bitCast(-2);

    cpu_id_start: u32 align(32),
    cpu_id: u32,

    cs: ?*CriticalSection,
    flags: CriticalSection.Flags,
};

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

inline fn validateMemoryPtr(base: usize) vm.Error!void {
    if (!vm.isUserVirtAddr(base)) return error.SegFault;
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
    trace.info("arch_prctl({x}, 0x{x})", .{op, addr});

    validateMemoryArgs(addr, @sizeOf(usize)) catch return errorFromE(.FAULT);
    const dest: ?*usize = @ptrFromInt(addr);

    arch.syscall.linuxArchPrCtl(op, dest) catch |err| {
        return errorFromZig(err);
    };

    return 0;
}

fn brk(new_brk: usize) callconv(.c) usize {
    const proc = sys.Process.getCurrent();
    const curr_brk = proc.addr_space.getHeapBreak();

    trace.info("brk(0x{x}); curr: 0x{x}", .{new_brk, curr_brk});

    if (new_brk == 0 or new_brk == curr_brk) return curr_brk;

    return if (new_brk > curr_brk) blk: {
        const diff = new_brk - curr_brk;
        break :blk proc.addr_space.heapGrow(diff) catch curr_brk;
    } else blk: {
        const diff = curr_brk - new_brk;
        break :blk proc.addr_space.heapShrink(diff) catch curr_brk;
    };
}

fn clockGetTime(clock: linux.clockid_t, time_ptr: ?*linux.timespec) isize {
    trace.info("clock_gettime({}, 0x{x})", .{@intFromEnum(clock), @intFromPtr(time_ptr)});

    const time_dest = time_ptr orelse return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(time_ptr), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);

    switch (clock) {
        .BOOTTIME,
        .BOOTTIME_ALARM => {
            const boot_time = sys.time.getBootTime();
            time_dest.sec = @intCast(boot_time.sec);
            time_dest.nsec = boot_time.ns;
        },
        .MONOTONIC,
        .MONOTONIC_RAW => {
            const uptime = sys.time.getUpTime();
            time_dest.sec = @intCast(uptime.sec);
            time_dest.nsec = uptime.ns;
        },
        .MONOTONIC_COARSE => {
            const cached = sys.time.getCachedUpTime();
            time_dest.sec = @intCast(cached.sec);
            time_dest.nsec = cached.ns;
        },
        .REALTIME,
        .REALTIME_ALARM => {
            const real = sys.time.getTime();
            time_dest.sec = @intCast(real.sec);
            time_dest.nsec = real.ns;
        },
        .REALTIME_COARSE => {
            const cached = sys.time.getCachedTime();
            time_dest.sec = @intCast(cached.sec);
            time_dest.nsec = cached.ns;
        },
        .THREAD_CPUTIME_ID => {
            const task = sched.getCurrentTask();
            const cpu_time = sys.time.Time.fromTicks(task.stats.cpu_time);

            time_dest.sec = @intCast(cpu_time.sec);
            time_dest.nsec = cpu_time.ns;
        },
        .PROCESS_CPUTIME_ID => {
            const task = sys.Process.getCurrent().getMainTask().?;
            const cpu_time = sys.time.Time.fromTicks(task.stats.cpu_time);

            time_dest.sec = @intCast(cpu_time.sec);
            time_dest.nsec = cpu_time.ns;
        },
        else => return errorFromE(.INVAL)
    }

    return 0;
}

fn stat(path: [*c]const u8, stats: *linux.Stat) isize {
    trace.info("stat(0x{x}, 0x{x})", .{@intFromPtr(path), @intFromPtr(stats)});

    validateMemoryArgs(@intFromPtr(path), linux.PATH_MAX) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const dentry = vfs.lookup(
        proc.root_dir, proc.work_dir, std.mem.span(path)
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return statImpl(dentry, stats);
}

fn fdAtGet(proc: *sys.Process, fd: linux.fd_t) ?*vfs.Dentry {
    if (fd == linux.AT.FDCWD) {
        proc.work_dir.ref();
        return proc.work_dir;
    }

    const file = proc.files.get(@intCast(fd)) orelse return null;
    defer file.deref();

    file.dentry.ref();
    return file.dentry;
}

fn fstat(fd: linux.fd_t, stats: *linux.Stat) isize {
    trace.info("fstat({}, 0x{x})", .{fd, @intFromPtr(stats)});

    const proc = sys.Process.getCurrent();
    const dentry = fdAtGet(proc, fd) orelse return errorFromE(.BADF);
    defer dentry.deref();

    return statImpl(dentry, stats);
}

fn fstatAt(fd: linux.fd_t, path: [*c]const u8, stats: *linux.Stat, flags: u32) isize {
    trace.info("fstatat64({}, 0x{x}, 0x{x}, 0x{x})", .{fd, @intFromPtr(path), @intFromPtr(stats), flags});

    validateMemoryArgs(@intFromPtr(path), linux.PATH_MAX) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(stats), @sizeOf(linux.Stat)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const dir = fdAtGet(proc, fd) orelse return errorFromE(.BADF);
    defer dir.deref();

    if (dir.inode.type != .directory) return errorFromE(.NOTDIR);
    const dentry = vfs.lookup(
        proc.root_dir, dir, std.mem.span(path)
    ) catch |err| return errorFromZig(err);

    return statImpl(dentry, stats);
}

fn statImpl(dentry: *vfs.Dentry, stats: *linux.Stat) isize {
    validateMemoryArgs(@intFromPtr(stats), @sizeOf(linux.Stat)) catch return errorFromE(.FAULT);
    const inode = dentry.inode;
    stats.* = .{
        // TODO: Implement access to device number from file struct
        .dev = 0,
        .ino = inode.index,
        .mode = inode.perm,
        .nlink = inode.links_num,
        .uid = inode.uid,
        .gid = inode.gid,
        // TODO: What is this?
        .rdev = 0,
        .size = @intCast(inode.size),
        .blksize = vm.page_size,
        .blocks = @intCast(inode.size + (512 - 1) / 512),
        // FIXME: Check if this code is correct
        .atim = .{ .sec = inode.access_time, .nsec = 0 },
        .mtim =  .{ .sec = inode.modify_time, .nsec = 0 },
        .ctim =  .{ .sec = inode.create_time, .nsec = 0 },
        .__pad0 = undefined,
        .__unused = undefined,
    };

    return 0;
}

fn getCwd(buf: [*]u8, len: usize) isize {
    trace.info("getcwd(0x{x}, {})", .{@intFromPtr(buf), len});

    if (@intFromPtr(buf) == 0 or len == 0) return errorFromE(.INVAL);
    validateMemoryArgs(@intFromPtr(buf), len) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    _ = std.fmt.bufPrint(buf[0..len], "{f}\x00", .{proc.work_dir.path()}) catch return errorFromE(.RANGE);

    return 0;
}

fn getEgid() linux.uid_t {
    trace.info("getegid()", .{});
    // TODO: Implement effective gid.

    const proc = sys.Process.getCurrent();
    return proc.gid;
}

fn getEuid() linux.uid_t {
    trace.info("geteuid()", .{});
    // TODO: Implement effective uid.

    const proc = sys.Process.getCurrent();
    return proc.uid;
}

fn getGid() linux.uid_t {
    trace.info("getgid()", .{});

    const proc = sys.Process.getCurrent();
    return proc.gid;
}

fn getUid() linux.uid_t {
    trace.info("getuid()", .{});

    const proc = sys.Process.getCurrent();
    return proc.uid;
}

fn getPid() sys.Process.Pid {
    trace.info("getpid()", .{});

    const proc = sys.Process.getCurrent();
    return proc.pid;
}

fn getParentPid() sys.Process.Pid {
    trace.info("getppid()", .{});

    const proc = sys.Process.getCurrent();
    if (proc.parent == proc) {
        @branchHint(.unlikely);
        return 0;
    }
    return proc.parent.pid;
}

fn getRandom(buffer: [*]u8, len: usize, flags: u32) isize {
    trace.info("getrandom(0x{x}, {}, 0x{x})", .{@intFromPtr(buffer), len, flags});

    validateMemoryArgs(@intFromPtr(buffer), len) catch return errorFromE(.FAULT);

    // TODO: Implement real /dev/random and /dev/urandom devices
    const seed = sys.time.getCachedTime().toNs() ^ @intFromPtr(buffer);
    var rand = std.Random.Xoroshiro128.init(seed);
    rand.fill(buffer[0..len]);

    return 0;
}

fn getRobustList(pid: sys.Process.Pid, head: *?*RobustList.Head, size: *usize) isize {
    trace.info("get_robust_list({}, 0x{x}, 0x{x})", .{pid, @intFromPtr(head), @intFromPtr(size)});

    const proc = sys.Process.getCurrent();
    if (pid != 0 and pid != proc.pid) return errorFromE(.INVAL);

    validateMemoryPtr(@intFromPtr(head)) catch return errorFromE(.FAULT);
    validateMemoryPtr(@intFromPtr(size)) catch return errorFromE(.FAULT);

    // TODO: Complete futex implementation.
    const abi_data = sched.getCurrentTask().spec.user.abi_data.asPtr(AbiData).?;
    size.* = @sizeOf(RobustList.Head);
    head.* = abi_data.robust_list;

    return 0;
}

fn getTid() sys.Process.Pid {
    trace.info("gettid()", .{});

    // TODO: Implement thread id.
    const proc = sys.Process.getCurrent();
    return proc.pid;
}

fn ioctl(fd: linux.fd_t, cmd: u32, arg: usize) isize {
    trace.info("ioctl({}, {}, 0x{x})", .{fd, cmd, arg});

    if (fd < 0) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    switch (file.dentry.inode.type) {
        .block_device,
        .char_device => {},
        else => return errorFromE(.NOTTY)
    }

    file.ioctl(cmd, arg) catch |err| return errorFromZig(err);
    return 0;
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
    const file = if (!flags.ANONYMOUS) blk: {
        if (fd < 0) return @bitCast(errorFromE(.BADF));

        const file = proc.files.get(@intCast(fd)) orelse return @bitCast(errorFromE(.BADF));
        if (!file.perm.checkAccess(mmap_flags.toPermissions())) return @bitCast(errorFromE(.ACCES));

        break :blk file;
    } else null;
    defer if (file) |f| f.deref();

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

fn mprotect(virt: usize, len: usize, prot: c_int) isize {
    trace.info("mprotect(0x{x}, 0x{x}, {})", .{virt, len, prot});
    
    if (!std.mem.isAligned(virt, vm.page_size) or
        !vm.isUserVirtAddr(virt +| len) or len == 0 or
        (prot & linux.PROT.GROWSUP != 0)
    ) return errorFromE(.INVAL);

    const mmap_flags: sys.AddressSpace.MapUnit.Flags = .{
        .grow_down = (prot & linux.PROT.GROWSDOWN) != 0,
        .shared = false,
        .map = .{
            .none = (prot == linux.PROT.NONE),
            .exec = (prot & linux.PROT.EXEC) != 0,
            .write = (prot & linux.PROT.WRITE) != 0,
            .user = true,
        }
    };

    const proc = sys.Process.getCurrent();
    const pages = vm.bytesToPages(len);
    proc.addr_space.protectRange(virt, pages, mmap_flags) catch |err| return errorFromZig(err);

    return 0;
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

fn prlimit64(pid: sys.Process.Pid, res: linux.rlimit_resource, old: ?*linux.rlimit, new: ?*const linux.rlimit) isize {
    trace.info("prlimit64({}, {}, 0x{x}, 0x{x})", .{pid, @intFromEnum(res), @intFromPtr(old), @intFromPtr(new)});

    const proc = sys.Process.getCurrent();
    // TODO: Implement access for other processes
    if (pid != 0 and pid != proc.pid) return errorFromE(.PERM);
    if (old == null and new == null) return errorFromE(.FAULT);

    if (old) |o| validateMemoryPtr(@intFromPtr(o)) catch return errorFromE(.FAULT);
    if (new) |n| validateMemoryPtr(@intFromPtr(n)) catch return errorFromE(.FAULT);

    // TODO: Implement limits for more resource types.
    switch (res) {
        .AS => {
            if (old) |o| {
                o.cur = linux.RLIM.INFINITY;
                o.max = linux.RLIM.INFINITY;
            }
        },
        .NOFILE => {
            if (old) |o| {
                o.cur = proc.files.max_files;
                o.max = std.math.maxInt(linux.fd_t);
            }
            if (new) |n| {
                if (n.max > std.math.maxInt(linux.fd_t)) return errorFromE(.INVAL);
                proc.files.setMaxFiles(@truncate(n.max)) catch return errorFromE(.INVAL);
            }
        },
        .STACK => {
            if (old) |o| {
                o.cur = @as(u64, proc.addr_space.stack_pages) * vm.page_size;
                o.max = linux.RLIM.INFINITY;
            }
            if (new) |n| {
                if (n.cur < vm.page_size) return errorFromE(.INVAL);
                proc.addr_space.stack_pages = @truncate(n.cur / vm.page_size);
            }
        },
        .DATA => {
            if (old) |o| {
                const used = proc.addr_space.calculateUsedRegion();
                o.cur = (used[1] - used[0]) / vm.page_size;
                o.max = linux.RLIM.INFINITY;
            } else return errorFromE(.FAULT);
        },
        else => return errorFromE(.INVAL)
    }

    return 0;
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

fn rseq(ptr: ?*RestartableSequence, size: u32, flags: RestartableSequence.CallFlags, sig: u32) isize {
    trace.info("rseq(0x{x}, {}, 0x{x}, 0x{x})", .{@intFromPtr(ptr), size, flags, sig});

    switch (flags) {
        .none, .unregister => {},
        else => return errorFromE(.INVAL)
    }

    const abi_data = sched.getCurrentTask().spec.user.abi_data.asPtr(AbiData).?;
    const set_ptr = ptr orelse if (flags == .unregister) {
        if (abi_data.rseq == null or abi_data.rseq_sig != sig) return errorFromE(.INVAL);

        abi_data.rseq = null;
        abi_data.rseq_sig = 0;

        return 0;
    } else return errorFromE(.FAULT);

    if (!std.mem.isAligned(@intFromPtr(set_ptr), @alignOf(RestartableSequence)) or
        size < @sizeOf(RestartableSequence)
    ) return errorFromE(.INVAL);

    validateMemoryArgs(
        @intFromPtr(set_ptr), @sizeOf(RestartableSequence)
    ) catch return errorFromE(.FAULT);

    const scheduler = sched.getCurrent();

    scheduler.disablePreemption();
    defer scheduler.enablePreemption();

    abi_data.rseq_sig = sig;
    abi_data.rseq = set_ptr;

    set_ptr.cpu_id = smp.getIdx();
    set_ptr.cpu_id_start = set_ptr.cpu_id;

    return 0;
}

fn setRobustList(head: ?*RobustList.Head, size: usize) isize {
    trace.info("set_robust_list(0x{x}, {});", .{@intFromPtr(head), size});

    if (size != @sizeOf(RobustList.Head)) {
        @branchHint(.unlikely);
        return errorFromE(.INVAL);
    }

    const abi_data = sched.getCurrentTask().spec.user.abi_data.asPtr(AbiData).?;
    abi_data.robust_list = head;

    return 0;
}

fn setTidAddress(addr: usize) sys.Process.Pid {
    trace.info("set_tid_address(0x{x})", .{addr});
    log.warn("{t} is not yet implemented", .{linux.SYS.set_tid_address});

    return sys.Process.getCurrent().pid;
}

fn time(tloc: ?*linux.time_t) isize {
    trace.info("time(0x{x})", .{@intFromPtr(tloc)});

    const epoch = sys.time.getEpoch();
    if (tloc) |ptr| {
        validateMemoryPtr(@intFromPtr(tloc)) catch return errorFromE(.FAULT);
        ptr.* = @intCast(epoch);
    }

    return @intCast(epoch);
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
