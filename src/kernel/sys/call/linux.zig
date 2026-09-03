//! # Linux ABI compatible syscalls implementation

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("opts");

const arch = lib.arch;
const lib = @import("../../lib.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.call.linux");
const net = @import("../../net.zig");
const posix = std.posix;
const sched = @import("../../sched.zig");
const smp = @import("../../smp.zig");
const sys = @import("../../sys.zig");
const trace = std.log.scoped(.@"sys.call.trace");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

const Error = sys.exe.Error || net.Error;

const SyscallFn = ?*const fn () callconv(.c) isize;

const table_len = 512;

pub const table: [table_len]SyscallFn = blk: {
    var result: [table_len]SyscallFn = .{ null } ** table_len;

    if (builtin.cpu.arch == .x86_64) {
        result[@intFromEnum(linux.SYS.arch_prctl)] = @ptrCast(&archPrCtl);
    }

    result[@intFromEnum(linux.SYS.accept)]          = @ptrCast(&accept);
    result[@intFromEnum(linux.SYS.accept4)]         = @ptrCast(&accept4);
    result[@intFromEnum(linux.SYS.access)]          = @ptrCast(&access);
    result[@intFromEnum(linux.SYS.bind)]            = @ptrCast(&bind);
    result[@intFromEnum(linux.SYS.brk)]             = @ptrCast(&brk);
    result[@intFromEnum(linux.SYS.chdir)]           = @ptrCast(&chdir);
    result[@intFromEnum(linux.SYS.chmod)]           = @ptrCast(&chmod);
    result[@intFromEnum(linux.SYS.chown)]           = @ptrCast(&chown);
    result[@intFromEnum(linux.SYS.clock_gettime)]   = @ptrCast(&clockGetTime);
    result[@intFromEnum(linux.SYS.clock_nanosleep)] = @ptrCast(&clockNanoSleep);
    result[@intFromEnum(linux.SYS.clone)]           = @ptrCast(arch.syscall.contextCall(clone, "clone"));
    result[@intFromEnum(linux.SYS.close)]           = @ptrCast(&close);
    result[@intFromEnum(linux.SYS.connect)]         = @ptrCast(&connect);
    result[@intFromEnum(linux.SYS.creat)]           = @ptrCast(&creat);
    result[@intFromEnum(linux.SYS.dup)]             = @ptrCast(&dup);
    result[@intFromEnum(linux.SYS.dup2)]            = @ptrCast(&dup2);
    result[@intFromEnum(linux.SYS.dup3)]            = @ptrCast(&dup3);
    result[@intFromEnum(linux.SYS.epoll_create)]    = @ptrCast(&epollCreate);
    result[@intFromEnum(linux.SYS.epoll_create1)]   = @ptrCast(&epollCreate1);
    result[@intFromEnum(linux.SYS.epoll_ctl)]       = @ptrCast(&epollControl);
    result[@intFromEnum(linux.SYS.epoll_pwait)]     = @ptrCast(&epollPwait);
    result[@intFromEnum(linux.SYS.epoll_pwait2)]    = @ptrCast(&epollPwait2);
    result[@intFromEnum(linux.SYS.epoll_wait)]      = @ptrCast(&epollWait);
    result[@intFromEnum(linux.SYS.execve)]          = @ptrCast(&execve);
    result[@intFromEnum(linux.SYS.exit)]            = @ptrCast(&exit);
    result[@intFromEnum(linux.SYS.exit_group)]      = @ptrCast(&exitGroup);
    result[@intFromEnum(linux.SYS.faccessat)]       = @ptrCast(&faccessAt);
    result[@intFromEnum(linux.SYS.faccessat2)]      = @ptrCast(&faccessAt2);
    result[@intFromEnum(linux.SYS.fchdir)]          = @ptrCast(&fchdir);
    result[@intFromEnum(linux.SYS.fchmod)]          = @ptrCast(&fchmod);
    result[@intFromEnum(linux.SYS.fchmodat)]        = @ptrCast(&fchmodAt);
    result[@intFromEnum(linux.SYS.fchmodat2)]       = @ptrCast(&fchmodAt2);
    result[@intFromEnum(linux.SYS.fchown)]          = @ptrCast(&fchown);
    result[@intFromEnum(linux.SYS.fchownat)]        = @ptrCast(&fchownAt);
    result[@intFromEnum(linux.SYS.fcntl)]           = @ptrCast(&fcntl);
    result[@intFromEnum(linux.SYS.fork)]            = @ptrCast(arch.syscall.contextCall(fork, "fork"));
    result[@intFromEnum(linux.SYS.fstat)]           = @ptrCast(&fstat);
    result[@intFromEnum(linux.SYS.fstatat64)]       = @ptrCast(&fstatAt);
    result[@intFromEnum(linux.SYS.ftruncate)]       = @ptrCast(&ftruncate);
    result[@intFromEnum(linux.SYS.futex)]           = @ptrCast(&futex);
    result[@intFromEnum(linux.SYS.get_robust_list)] = @ptrCast(&getRobustList);
    result[@intFromEnum(linux.SYS.getcwd)]          = @ptrCast(&getCwd);
    result[@intFromEnum(linux.SYS.getdents64)]      = @ptrCast(&getDentries);
    result[@intFromEnum(linux.SYS.getegid)]         = @ptrCast(&getEgid);
    result[@intFromEnum(linux.SYS.geteuid)]         = @ptrCast(&getEuid);
    result[@intFromEnum(linux.SYS.getgid)]          = @ptrCast(&getGid);
    result[@intFromEnum(linux.SYS.getpgid)]         = @ptrCast(&getProcGroupById);
    result[@intFromEnum(linux.SYS.getpgrp)]         = @ptrCast(&getProcGroup);
    result[@intFromEnum(linux.SYS.getpid)]          = @ptrCast(&getPid);
    result[@intFromEnum(linux.SYS.getppid)]         = @ptrCast(&getParentPid);
    result[@intFromEnum(linux.SYS.getrandom)]       = @ptrCast(&getRandom);
    result[@intFromEnum(linux.SYS.gettid)]          = @ptrCast(&getTid);
    result[@intFromEnum(linux.SYS.gettimeofday)]    = @ptrCast(&getTimeOfDay);
    result[@intFromEnum(linux.SYS.getuid)]          = @ptrCast(&getUid);
    result[@intFromEnum(linux.SYS.ioctl)]           = @ptrCast(&ioctl);
    result[@intFromEnum(linux.SYS.lchown)]          = @ptrCast(&lchown);
    result[@intFromEnum(linux.SYS.link)]            = @ptrCast(&link);
    result[@intFromEnum(linux.SYS.listen)]          = @ptrCast(&listen);
    result[@intFromEnum(linux.SYS.lseek)]           = @ptrCast(&seek);
    result[@intFromEnum(linux.SYS.lstat)]           = @ptrCast(&lstat);
    result[@intFromEnum(linux.SYS.mkdir)]           = @ptrCast(&mkdir);
    result[@intFromEnum(linux.SYS.mkdirat)]         = @ptrCast(&mkdirAt);
    result[@intFromEnum(linux.SYS.mmap)]            = @ptrCast(&mmap);
    result[@intFromEnum(linux.SYS.mprotect)]        = @ptrCast(&mprotect);
    result[@intFromEnum(linux.SYS.mremap)]          = @ptrCast(&mremap);
    result[@intFromEnum(linux.SYS.munmap)]          = @ptrCast(&munmap);
    result[@intFromEnum(linux.SYS.nanosleep)]       = @ptrCast(&nanoSleep);
    result[@intFromEnum(linux.SYS.open)]            = @ptrCast(&open);
    result[@intFromEnum(linux.SYS.openat)]          = @ptrCast(&openAt);
    result[@intFromEnum(linux.SYS.pipe)]            = @ptrCast(&pipe);
    result[@intFromEnum(linux.SYS.poll)]            = @ptrCast(&poll);
    result[@intFromEnum(linux.SYS.pread64)]         = @ptrCast(&pread);
    result[@intFromEnum(linux.SYS.preadv)]          = @ptrCast(&preadv);
    result[@intFromEnum(linux.SYS.prlimit64)]       = @ptrCast(&prlimit64);
    result[@intFromEnum(linux.SYS.pselect6)]        = @ptrCast(&pselect);
    result[@intFromEnum(linux.SYS.pwrite64)]        = @ptrCast(&pwrite);
    result[@intFromEnum(linux.SYS.pwritev)]         = @ptrCast(&pwritev);
    result[@intFromEnum(linux.SYS.read)]            = @ptrCast(&read);
    result[@intFromEnum(linux.SYS.readlink)]        = @ptrCast(&readLink);
    result[@intFromEnum(linux.SYS.readlinkat)]      = @ptrCast(&readLinkAt);
    result[@intFromEnum(linux.SYS.readv)]           = @ptrCast(&readv);
    result[@intFromEnum(linux.SYS.recvfrom)]        = @ptrCast(&receiveFrom);
    result[@intFromEnum(linux.SYS.recvmsg)]         = @ptrCast(&receiveMessage);
    result[@intFromEnum(linux.SYS.rseq)]            = @ptrCast(&rseq);
    result[@intFromEnum(linux.SYS.rmdir)]           = @ptrCast(&rmdir);
    result[@intFromEnum(linux.SYS.rt_sigaction)]    = @ptrCast(&sigAction);
    result[@intFromEnum(linux.SYS.rt_sigprocmask)]  = @ptrCast(&sigProcMask);
    result[@intFromEnum(linux.SYS.rt_sigreturn)]    = @ptrCast(arch.syscall.contextCall(sigReturn, "sigReturn"));
    result[@intFromEnum(linux.SYS.rt_sigsuspend)]   = @ptrCast(&sigSuspend);
    result[@intFromEnum(linux.SYS.select)]          = @ptrCast(&select);
    result[@intFromEnum(linux.SYS.sendmsg)]         = @ptrCast(&sendMessage);
    result[@intFromEnum(linux.SYS.sendto)]          = @ptrCast(&sendTo);
    result[@intFromEnum(linux.SYS.set_robust_list)] = @ptrCast(&setRobustList);
    result[@intFromEnum(linux.SYS.set_tid_address)] = @ptrCast(&setTidAddress);
    result[@intFromEnum(linux.SYS.sethostname)]     = @ptrCast(&setHostName);
    result[@intFromEnum(linux.SYS.setpgid)]         = @ptrCast(&setProcGroup);
    result[@intFromEnum(linux.SYS.socket)]          = @ptrCast(&socket);
    result[@intFromEnum(linux.SYS.stat)]            = @ptrCast(&stat);
    result[@intFromEnum(linux.SYS.symlink)]         = @ptrCast(&symlink);
    result[@intFromEnum(linux.SYS.symlinkat)]       = @ptrCast(&symlinkAt);
    //result[@intFromEnum(linux.SYS.tgkill)]          = @ptrCast(&tgkill);
    result[@intFromEnum(linux.SYS.tkill)]           = @ptrCast(&tkill);
    result[@intFromEnum(linux.SYS.time)]            = @ptrCast(&time);
    result[@intFromEnum(linux.SYS.truncate)]        = @ptrCast(&truncate);
    result[@intFromEnum(linux.SYS.umask)]           = @ptrCast(&umask);
    result[@intFromEnum(linux.SYS.uname)]           = @ptrCast(&uname);
    result[@intFromEnum(linux.SYS.unlink)]          = @ptrCast(&unlink);
    result[@intFromEnum(linux.SYS.unlinkat)]        = @ptrCast(&unlinkAt);
    result[@intFromEnum(linux.SYS.utime)]           = @ptrCast(&utime);
    result[@intFromEnum(linux.SYS.utimensat)]       = @ptrCast(&utimeNsAt);
    result[@intFromEnum(linux.SYS.utimes)]          = @ptrCast(&utimes);
    result[@intFromEnum(linux.SYS.wait4)]           = @ptrCast(&waitPid);
    result[@intFromEnum(linux.SYS.write)]           = @ptrCast(&write);
    result[@intFromEnum(linux.SYS.writev)]          = @ptrCast(&writev);
    result[@intFromEnum(linux.SYS.vfork)]           = @ptrCast(arch.syscall.contextCall(vfork, "vfork"));

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
    rseq_sig: u32 = 0,
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

const DirectoryIterator = struct {
    iter: vfs.Dentry.Iterator,
    buffer: []u8,

    fn init(pos: usize, buffer: []u8) DirectoryIterator {
        return .{
            .iter = .{ .pos = pos, .callback = &fill },
            .buffer = buffer,
        };
    }

    fn fill(
        iter: *vfs.Dentry.Iterator, name: []const u8,
        inode: usize, @"type": vfs.Inode.Type
    ) bool {
        const self: *DirectoryIterator = @fieldParentPtr("iter", iter);
        if (self.buffer.len -| @sizeOf(linux.dirent64) < name.len) return false;

        const dent: *linux.dirent64 = @alignCast(@ptrCast(self.buffer.ptr));
        const name_dest: [*]u8 = @ptrCast(&dent.name);
        const size = lib.misc.alignUp(
            usize, @sizeOf(linux.dirent64) + name.len, @alignOf(linux.dirent64)
        );

        dent.* = .{
            .name = undefined,
            .ino = inode,
            .off = 0,
            .reclen = @truncate(size),
            .type = switch (@"type") {
                .unknown       => linux.DT.UNKNOWN,
                .regular_file  => linux.DT.REG,
                .directory     => linux.DT.DIR,
                .char_device   => linux.DT.CHR,
                .block_device  => linux.DT.BLK,
                .fifo          => linux.DT.FIFO,
                .socket        => linux.DT.SOCK,
                .symbolic_link => linux.DT.LNK
            },
        };

        @memcpy(name_dest[0..name.len], name);
        name_dest[name.len] = 0;

        if (dent.reclen > self.buffer.len) {
            @branchHint(.unlikely);
            dent.reclen = @truncate(self.buffer.len);
            self.buffer = self.buffer[self.buffer.len..];
            return true;
        }

        self.buffer = self.buffer[dent.reclen..];
        return true;
    }

    inline fn getReadedBytes(self: *const DirectoryIterator, buffer_base: [*]u8) usize {
        return @intFromPtr(self.buffer.ptr) - @intFromPtr(buffer_base);
    }
};

/// Source: https://elixir.bootlin.com/linux/v7.0.6/source/include/uapi/linux/utime.h#L7
const UtimeBuffer = extern struct {
    acc_time: c_long,
    mod_time: c_long,
};

inline fn errorFromE(comptime e: linux.E) isize {
    trace.info("return error: {t}", .{e});
    const code: isize = comptime @intFromEnum(e);
    return -code;
}

fn errorFromZig(e: Error) isize {
    return switch (e) {
        error.BadAbi,
        error.BadFormat         => errorFromE(.NOEXEC),
        error.BadFileDescriptor => errorFromE(.BADF),
        error.BadInterpreter    => errorFromE(.LIBBAD),
        error.BadLbaSize,
        error.BadName           => errorFromE(.INVAL),
        error.BadOperation      => errorFromE(.OPNOTSUPP),
        error.BadPipe           => errorFromE(.PIPE),
        error.BadSuperblock     => errorFromE(.INVAL),
        error.Busy              => errorFromE(.BUSY),
        error.DevMajorLimit     => errorFromE(.BUSY),
        error.DevMinorLimit     => errorFromE(.BUSY),
        error.Exists            => errorFromE(.EXIST),
        error.Interrupted       => errorFromE(.INTR),
        error.InvalidArgs       => errorFromE(.INVAL),
        error.IoFailed          => errorFromE(.IO),
        error.MaxSize           => errorFromE(.FBIG),
        error.NameTooLong       => errorFromE(.NAMETOOLONG),
        error.NoAccess          => errorFromE(.ACCES),
        error.NoEnt             => errorFromE(.NOENT),
        error.NoMemory          => errorFromE(.NOMEM),
        error.NoSpace           => errorFromE(.NOSPC),
        error.NoTTY             => errorFromE(.NOTTY),
        error.NotDirectory      => errorFromE(.NOTDIR),
        error.NotEmpty          => errorFromE(.NOTEMPTY),
        error.NotRegularFile    => errorFromE(.ISDIR),
        error.SegFault          => errorFromE(.FAULT),
        error.NoFs,
        error.TooManyLinks      => errorFromE(.LOOP),
        error.Uninitialized     => errorFromE(.NODEV),
        // Network specific errors.
        error.AddressInUse      => errorFromE(.ADDRINUSE),
        error.Already           => errorFromE(.ALREADY),
        error.Connected         => errorFromE(.ISCONN),
        error.ConnectionRefused => errorFromE(.CONNREFUSED),
        error.InProgress => errorFromE(.INPROGRESS),
        error.MessageTooBig => errorFromE(.MSGSIZE),
        error.NotConnected      => errorFromE(.NOTCONN),
        error.NotSocket => errorFromE(.NOTSOCK),
        error.ProtocolTypeMissmatch => errorFromE(.PROTOTYPE),
        error.Timeout => errorFromE(.TIMEDOUT),
        error.UnsupportedFamily => errorFromE(.AFNOSUPPORT),
        error.UnsupportedProtocol => errorFromE(.PROTONOSUPPORT),
        error.UnsupportedSocketType => errorFromE(.SOCKTNOSUPPORT),
    };
}

inline fn validateMemoryArgs(base: usize, len: usize) vm.Error!void {
    if (!vm.isUserVirtAddr(base) or !vm.isUserVirtAddr(base +| len)) {
        return error.SegFault;
    }
}

inline fn validateMemoryPtr(base: usize) vm.Error!void {
    if (base == 0 or !vm.isUserVirtAddr(base)) return error.SegFault;
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

fn access(path: [*:0]const u8, mode: u16) isize {
    trace.info("access(0x{x}, 0o{o})", .{@intFromPtr(path), mode});
    return accessImpl(linux.AT.FDCWD, path, mode, 0);
}

fn faccessAt(fd: linux.fd_t, path: [*:0]const u8, mode: u16) isize {
    trace.info("faccessat({}, 0x{x}, 0o{o})", .{fd, @intFromPtr(path), mode});
    return accessImpl(fd, path, mode, 0);
}

fn faccessAt2(fd: linux.fd_t, path: [*:0]const u8, mode: u16, flags: u32) isize {
    trace.info("faccessat2({}, 0x{x}, 0o{o}, 0x{x})", .{fd, @intFromPtr(path), mode, flags});
    return accessImpl(fd, path, mode, flags);
}

fn accessImpl(fd: linux.fd_t, path: [*:0]const u8, mode: u16, flags: u32) isize {
    const proc = sys.Process.getCurrent();
    const dentry = fdAtLookup(
        proc, fd, path,flags
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    if (mode == linux.F_OK) return 0;

    const role = dentry.inode.getRole(proc.uid, proc.gid);
    var perm: u16 = 0;
    if (mode & (linux.R_OK) != 0) perm |= @intFromEnum(vfs.Permissions.r);
    if (mode & (linux.W_OK) != 0) perm |= @intFromEnum(vfs.Permissions.w);
    if (mode & (linux.X_OK) != 0) perm |= @intFromEnum(vfs.Permissions.w);

    if (!dentry.inode.checkAccess(@enumFromInt(perm), role)) return errorFromE(.ACCES);
    return 0;
}

fn getSocketByFd(fd: linux.fd_t) Error!struct{ *vfs.File, *net.Socket } {
    if (fd < 0) return error.BadFileDescriptor;

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return error.BadFileDescriptor;
    errdefer file.deref();

    if (file.type != .socket) return error.NotSocket;

    return .{ file, net.Socket.fromFile(file) };
}

fn getNetAddressData(
    sock: *net.Socket,
    address: *const linux.sockaddr,
    len: linux.socklen_t,
) Error![]const u8 {
    const data_offset = @offsetOf(linux.sockaddr, "data");
    if (len < data_offset) return error.InvalidArgs;

    try validateMemoryArgs(@intFromPtr(address), @sizeOf(linux.sockaddr));

    if (address.family != @intFromEnum(sock.family)) return error.InvalidArgs;
    const data_ptr: [*]const u8 = @ptrCast(&address.data[0]);
    const data_len = @as(u32, @intCast(len)) - data_offset;

    return data_ptr[0..data_len];
}

fn accept(fd: linux.fd_t, address: ?*linux.sockaddr, len: ?*linux.socklen_t) isize {
    trace.info("accept({}, 0x{x}, 0x{x})", .{fd, @intFromPtr(address), @intFromPtr(len)});

    return acceptImpl(fd, address, len, 0);
}

fn accept4(fd: linux.fd_t, address: ?*linux.sockaddr, len: ?*linux.socklen_t, flags: u32) isize {
    trace.info("accept4({}, 0x{x}, 0x{x}, 0x{x})", .{
        fd, @intFromPtr(address), @intFromPtr(len), flags
    });

    return acceptImpl(fd, address, len, flags);
}

fn acceptImpl(fd: linux.fd_t, address: ?*linux.sockaddr, len: ?*linux.socklen_t, flags: u32) isize {
    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    var out_address: []u8 = &.{};
    const out_ptr = if (address) |addr| blk: {
        const len_ptr = len orelse return errorFromE(.FAULT);
        validateMemoryArgs(@intFromPtr(len), @sizeOf(linux.socklen_t)) catch return errorFromE(.FAULT);

        const data = getNetAddressData(
            sock, addr, len_ptr.*
        ) catch |err| return errorFromZig(err);

        out_address = @constCast(data);
        break :blk &out_address;
    } else null;

    const proc = sys.Process.getCurrent();
    const new_fd = sock.acceptAsFileDescriptor(out_ptr) catch |err| return errorFromZig(err);
    const new_sock = net.Socket.fromFile(new_fd);
    const desc = proc.files.newDescriptor(new_fd) catch |err| {
        new_fd.deref();
        return errorFromZig(err);
    };

    if (out_ptr != null) len.?.* = @truncate(out_address.len);
    if ((flags & linux.SOCK.NONBLOCK) != 0) new_sock.flags.non_block = true;
    if ((flags & linux.SOCK.CLOEXEC) != 0) _ = proc.files.setCloseOnExec(desc.idx, true);

    return desc.idx;
}

fn bind(fd: linux.fd_t, address: *const linux.sockaddr, len: linux.socklen_t) isize {
    trace.info("bind({}, 0x{x}, {})", .{fd, @intFromPtr(address), len});

    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    const data = getNetAddressData(
        sock, address, len
    ) catch |err| return errorFromZig(err);

    sock.bind(data) catch |err| return errorFromZig(err);
    log.debug("socket binded to address '{s}'", .{data});

    return 0;
}

fn connect(fd: linux.fd_t, address: *const linux.sockaddr, len: linux.socklen_t) isize {
    trace.info("connect({}, 0x{x}, {})", .{fd, @intFromPtr(address), len});

    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    const data = getNetAddressData(
        sock, address, len
    ) catch |err| return errorFromZig(err);

    log.debug("connectinig to '{s}'", .{data});
    sock.connect(data) catch |err| return errorFromZig(err);

    return 0;
}

fn listen(fd: linux.fd_t, backlog: i32) isize {
    trace.info("listen({}, {})", .{fd, backlog});
    if (fd < 0) return errorFromE(.BADF);

    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    const default_limit = 16;
    const limit: u32 = if (backlog < 1) default_limit else @intCast(backlog);

    sock.listen(limit) catch |err| return errorFromZig(err);

    return 0;
}

fn receiveFrom(
    fd: linux.fd_t, buffer: [*]u8, len: usize,
    flags: u32, address: ?*linux.sockaddr, addr_len: ?*linux.socklen_t,
) isize {
    trace.info("recvfrom({}, 0x{x}, {}, 0x{x}, 0x{x}, 0x{x})", .{
        fd, @intFromPtr(buffer), len, flags, @intFromPtr(address), @intFromPtr(addr_len)
    });

    const addr_buf_len: u32 = if (addr_len) |al| blk: {
        validateMemoryArgs(@intFromPtr(al), @sizeOf(linux.socklen_t)) catch return errorFromE(.FAULT);
        break :blk al.*;
    } else 0;

    var iov: posix.iovec = .{ .base = buffer, .len = len };
    var msg: linux.msghdr = .{
        .control = null,
        .controllen = 0,
        .flags = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .name = address,
        .namelen = addr_buf_len,
    };

    const result = receiveImpl(fd, &msg, flags, true);
    if (result < 0) return result;
    if (addr_len) |al| al.* = msg.namelen;

    return result;
}

fn receiveMessage(fd: linux.fd_t, msg: *linux.msghdr, flags: u32) isize {
    trace.info("recvmsg({}, 0x{x}, {})", .{fd, @intFromPtr(msg), flags});
    return receiveImpl(fd, msg, flags, false);
}

fn receiveImpl(fd: linux.fd_t, msg: *linux.msghdr, flags: u32, kernel: bool) isize {
    const iovecs = if (!kernel) blk: {
        const iovecs = msg.iov[0..msg.iovlen];
        validateMemoryArgs(@intFromPtr(msg), @sizeOf(linux.msghdr)) catch return errorFromE(.FAULT);
        validateMemoryArgs(@intFromPtr(iovecs.ptr), iovecs.len * @sizeOf(posix.iovec)) catch return errorFromE(.FAULT);

        break :blk iovecs;
    } else msg.iov[0..msg.iovlen];

    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    var out_address: []u8 = &.{};
    const out_ptr = if (msg.name) |addr| blk: {
        const data = getNetAddressData(
            sock, addr, msg.namelen
        ) catch |err| return errorFromZig(err);
        out_address = @constCast(@ptrCast(data));
        break :blk &out_address;
    } else null;

    const io_flags: net.IoFlags = @bitCast(@as(u16, @truncate(flags)));
    var total_received: usize = 0;
    for (iovecs) |*io| {
        const buffer = io.base[0..io.len];
        validateMemoryArgs(@intFromPtr(buffer.ptr), buffer.len) catch return errorFromE(.FAULT);

        const received = sock.receive(
            buffer, out_ptr, io_flags
        ) catch |err| return errorFromZig(err);

        io.len = received;
        total_received += received;
    }

    msg.namelen = @truncate(out_address.len);

    return @intCast(total_received);
}

fn sendTo(
    fd: linux.fd_t, buffer: [*]const u8, len: usize,
    flags: u32, address: *const linux.sockaddr, addr_len: linux.socklen_t,
) isize {
    trace.info("sendto({}, 0x{x}, {}, 0x{x}, 0x{x}, {})", .{
        fd, @intFromPtr(buffer), len, flags, @intFromPtr(address), addr_len
    });

    const iov: posix.iovec_const = .{ .base = @constCast(buffer), .len = len };
    const msg: linux.msghdr_const = .{
        .control = null,
        .controllen = 0,
        .flags = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .name = address,
        .namelen = addr_len,
    };

    return sendImpl(fd, &msg, flags, true);
}

fn sendMessage(fd: linux.fd_t, msg: *const linux.msghdr_const, flags: u32) isize {
    trace.info("sendmsg({}, 0x{x}, {})", .{fd, @intFromPtr(msg), flags});
    return sendImpl(fd, msg, flags, false);
}

fn sendImpl(fd: linux.fd_t, msg: *const linux.msghdr_const, flags: u32, kernel: bool) isize {
    const iovecs = if (!kernel) blk: {
        const iovecs = msg.iov[0..msg.iovlen];
        validateMemoryArgs(@intFromPtr(msg), @sizeOf(linux.msghdr)) catch return errorFromE(.FAULT);
        validateMemoryArgs(@intFromPtr(iovecs.ptr), iovecs.len * @sizeOf(posix.iovec)) catch return errorFromE(.FAULT);

        break :blk iovecs;
    } else msg.iov[0..msg.iovlen];

    const file,
    const sock = getSocketByFd(fd) catch |err| return errorFromZig(err);
    defer file.deref();

    const address = if (msg.name) |addr| blk: {
        break :blk getNetAddressData(
            sock, addr, msg.namelen
        ) catch |err| return errorFromZig(err);
    } else null;

    var total_size: usize = 0;
    for (iovecs) |io| {
        const data = io.base[0..io.len];
        validateMemoryArgs(@intFromPtr(data.ptr), data.len) catch return errorFromE(.FAULT);

        total_size += io.len;
    }

    if (total_size > net.Packet.max_size) return errorFromE(.MSGSIZE);

    const packet = net.Packet.new(@truncate(total_size)) catch return errorFromE(.NOMEM);
    var copied: usize = 0;
    for (iovecs) |io| {
        @memcpy(packet.buffer[copied..copied + io.len], io.base[0..io.len]);
        copied += io.len;
    }

    const io_flags: net.IoFlags = @bitCast(@as(u16, @truncate(flags)));
    const sended = sock.send(packet, address, io_flags) catch |err| {
        packet.delete();
        return errorFromZig(err);
    };

    return @intCast(sended);
}

fn socket(domain: u32, @"type": u32, protocol: u32) isize {
    trace.info("socket({}, {}, {})", .{domain, @"type", protocol});

    if (domain >= net.Family.max) return errorFromE(.AFNOSUPPORT);

    const raw_type = @"type" & ~@as(u32, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
    const sock_type = std.enums.fromInt(net.Socket.Type, raw_type) orelse return errorFromE(.INVAL);
    const file = net.Socket.create(
        @enumFromInt(domain), sock_type
    ) catch |err| return errorFromZig(err);

    const sock = net.Socket.fromFile(file);
    sock.flags.non_block = (@"type" & linux.SOCK.NONBLOCK) != 0;

    const proc = sys.Process.getCurrent();
    const desc = proc.files.newDescriptor(file) catch |err| {
        file.deref();
        return errorFromZig(err);
    };

    if ((@"type" & linux.SOCK.CLOEXEC) != 0) {
        _ = proc.files.setCloseOnExec(desc.idx, true);
    }

    log.debug("socket fd: {}", .{desc.idx});
    return desc.idx;
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
            const cached = sys.time.getUpTime();
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
            const cached = sys.time.getTime();
            time_dest.sec = @intCast(cached.sec);
            time_dest.nsec = cached.ns;
        },
        .THREAD_CPUTIME_ID => {
            const task = sched.getCurrentTask();
            const cpu_time = sys.time.Time.fromNs(task.stats.sys_time_ns +% task.stats.user_time_ns);

            time_dest.sec = @intCast(cpu_time.sec);
            time_dest.nsec = cpu_time.ns;
        },
        .PROCESS_CPUTIME_ID => {
            const task = sys.Process.getCurrent().getMainTask().?;
            const cpu_time = sys.time.Time.fromNs(task.stats.sys_time_ns +% task.stats.user_time_ns);

            time_dest.sec = @intCast(cpu_time.sec);
            time_dest.nsec = cpu_time.ns;
        },
        else => return errorFromE(.INVAL)
    }

    return 0;
}

fn clockNanoSleep(
    clock: linux.clockid_t,
    flags: linux.TIMER,
    request: *const linux.timespec,
    remain: ?*linux.timespec,
) isize {
    trace.info("clock_nanosleep({}, 0x{x}, 0x{x}, 0x{x})", .{
        @intFromEnum(clock), @as(u32, @bitCast(flags)), @intFromPtr(request), @intFromPtr(remain)
    });

    validateMemoryArgs(@intFromPtr(request), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);
    if (remain != null) validateMemoryArgs(@intFromPtr(remain), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);

    if (
        request.sec < 0 or
        request.nsec < 0 or
        request.nsec >= std.time.ns_per_s
    ) return errorFromE(.INVAL);

    const ns_to_wait = (@as(u64, @intCast(request.sec)) * std.time.ns_per_s) + @as(u64, @intCast(request.nsec));
    const start_time_ns = sys.time.getUpTimeNs();
    const abs_start_time_ns = if (flags.ABSTIME) switch (clock) {
            .REALTIME => sys.time.getTime(),
            .BOOTTIME => sys.time.getBootTime(),
            .MONOTONIC => sys.time.getUpTime(),
            else => return errorFromE(.INVAL),
    }.toNs() else 0;

    if (abs_start_time_ns >= ns_to_wait) return 0;

    const wait_time_ns = ns_to_wait -| start_time_ns;
    sched.sleepFor(wait_time_ns) catch {
        setRemainTime(remain, start_time_ns, wait_time_ns);
        return errorFromE(.INTR);
    };

    return 0;
}

fn nanoSleep(request: *const linux.timespec, remain: ?*linux.timespec) isize {
    trace.info("nanosleep(0x{x}, 0x{x})", .{@intFromPtr(request), @intFromPtr(remain)});

    validateMemoryArgs(@intFromPtr(request), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);
    if (remain != null) validateMemoryArgs(@intFromPtr(remain), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);

    const start_time_ns = sys.time.getUpTimeNs();
    const wait_time_ns = (@as(u64, @intCast(request.sec)) * std.time.ns_per_s) + @as(u64, @intCast(request.nsec));

    sched.sleepFor(wait_time_ns) catch {
        setRemainTime(remain, start_time_ns, wait_time_ns);
        return errorFromE(.INTR);
    };

    return 0;
}

fn setRemainTime(remain: ?*linux.timespec, start_time_ns: u64, wait_time_ns: u64) void {
    const r = remain orelse return;
    const end_time_ns = start_time_ns +| wait_time_ns;
    const remain_ns = end_time_ns -| sys.time.getUpTimeNs();

    r.sec = @intCast(remain_ns / std.time.ns_per_s);
    r.nsec = @intCast(remain_ns % std.time.ns_per_s);
}

fn clone(
    ctx: *arch.syscall.Context, sp: usize, parent_tid: *u32,
    child_tid: *u32, tls: usize, flags: usize
) callconv(.c) isize {
    trace.info("clone(0x{x}, 0x{x}, 0x{x}, 0x{x}, 0x{x})", .{
        flags, sp, @intFromPtr(parent_tid), @intFromPtr(child_tid), tls
    });

    // Currently this flags is not implemented.
    if ((flags & linux.CLONE.THREAD) != 0 or
        (flags & linux.CLONE.DETACHED) != 0 or
        (flags & linux.CLONE.NEWCGROUP) != 0 or
        (flags & linux.CLONE.NEWTIME) != 0 or
        (flags & linux.CLONE.NEWUSER) != 0 or
        (flags & linux.CLONE.NEWIPC) != 0 or
        (flags & linux.CLONE.NEWNET) != 0 or
        (flags & linux.CLONE.NEWPID) != 0 or
        (flags & linux.CLONE.FILES) != 0 or
        (flags & linux.CLONE.VFORK) != 0 or
        (flags & linux.CLONE.FS) != 0 or
        (flags & linux.CLONE.IO) != 0 or
        (flags & linux.CLONE.VM) != 0
    ) return errorFromE(.NOSYS);

    const new_proc = cloneImpl(ctx) catch |err| return errorFromZig(err);
    const new_task = new_proc.getMainTask().?;

    if ((flags & linux.CLONE.CHILD_SETTID) != 0) {
        validateMemoryPtr(@intFromPtr(child_tid)) catch return errorFromE(.FAULT);
        child_tid.* = new_proc.id.value;
    }
    if ((flags & linux.CLONE.PARENT_SETTID) != 0) {
        validateMemoryPtr(@intFromPtr(parent_tid)) catch return errorFromE(.FAULT);
        parent_tid.* = new_proc.id.value;
    }
    if (sp != 0) {
        @branchHint(.cold);
        log.warn("non-null stack ptr: 0x{x} while CLONE_VM flag is not specified", .{sp});
    }

    sched.enqueue(new_task);
    return new_proc.id.value;
}

fn cloneImpl(ctx: *arch.syscall.Context) vfs.Error!*sys.Process {
    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;

    const new_proc = try proc.clone();
    errdefer new_proc.delete();

    const new_task = new_proc.createTask() catch return error.NoMemory;
    try sys.call.cloneThread(
        .linux_sysv, task, new_task,  ctx
    );

    return new_proc;
}

fn fork(ctx: *arch.syscall.Context) callconv(.c) isize {
    trace.info("fork() ctx: 0x{x}, 0x{x}, 0x{x}", .{ctx.rcx, ctx.rsp, ctx.rbp});

    const new_proc = cloneImpl(ctx) catch |err| return errorFromZig(err);
    const new_task = new_proc.getMainTask().?;

    sched.enqueue(new_task);
    return new_proc.id.value;
}

fn vfork(ctx: *arch.syscall.Context) callconv(.c) isize {
    trace.info("vfork()", .{});
    // TODO: Implement a real vfork, not just this stub

    const proc = sys.Process.getCurrent();
    const new_proc = cloneImpl(ctx) catch |err| return errorFromZig(err);
    const new_task = new_proc.getMainTask().?;
    const child_id = new_proc.id;

    sched.enqueue(new_task);

    proc.id.lock.lock();
    defer proc.id.lock.unlock();

    while (!child_id.isZombie()) {
        defer proc.id.lock.lock();

        const id = proc.id.waitForEventAtomic() catch continue;
        id.deref();
    }

    return child_id.value;
}

fn close(fd: linux.fd_t) isize {
    const proc = sys.Process.getCurrent();

    trace.info("close({}): {f}", .{fd, proc});
    if (fd < 0) return errorFromE(.BADF);

    proc.files.close(@intCast(fd)) catch |err| return errorFromZig(err);

    return 0;
}

fn chdir(path: [*c]const u8) isize {
    trace.info("chdir(0x{x})", .{path});
    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const path_slice = std.mem.span(path);

    const dentry = vfs.lookup(
        proc.root_dir,
        proc.work_dir,
        path_slice
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return chdirImpl(proc, dentry);
}

fn fchdir(fd: linux.fd_t) isize {
    trace.info("fchdir({})", .{fd});
    if (fd < 0) return errorFromE(.BADF);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    return chdirImpl(proc, file.dentry);
}

fn chdirImpl(proc: *sys.Process, dentry: *vfs.Dentry) isize {
    const inode = dentry.inode;
    if (inode.type != .directory) return errorFromE(.NOTDIR);

    const role = inode.getRole(proc.uid, proc.gid);
    if (!inode.checkAccess(.r, role)) return errorFromE(.ACCES);

    proc.ctrl.lock.lock();
    defer proc.ctrl.lock.unlock();

    const old_dir = proc.work_dir;
    dentry.ref();
    defer old_dir.deref();

    proc.work_dir = dentry;
    return 0;
}

fn chmod(path: [*:0]const u8, mode: u16) isize {
    trace.info("chmod(0x{x}, 0o{o})", .{@intFromPtr(path), mode});
    return chmodImpl(linux.AT.FDCWD, path, mode, 0);
}

fn fchmod(fd: linux.fd_t, mode: u16) isize {
    trace.info("fchmod({}, 0o{o})", .{fd, mode});
    return chmodImpl(fd, undefined, mode, linux.AT.EMPTY_PATH);
}

fn fchmodAt(dir_fd: linux.fd_t, path: [*:0]const u8, mode: u16) isize {
    trace.info("fchmodat({}, 0x{x}, 0o{o})", .{dir_fd, @intFromPtr(path), mode});
    return chmodImpl(dir_fd, path, mode, 0);
}

fn fchmodAt2(dir_fd: linux.fd_t, path: [*:0]const u8, mode: u16, flags: u32) isize {
    trace.info("fchmodat2({}, 0x{x}, 0o{o}, 0x{x})", .{
        dir_fd, @intFromPtr(path), mode, flags
    });
    return chmodImpl(dir_fd, path, mode, flags);
}

fn chmodImpl(dir_fd: linux.fd_t, path: [*:0]const u8, mode: u16, flags: u32) isize {
    const proc = sys.Process.getCurrent();
    const dentry = fdAtLookup(
        proc, dir_fd, path, flags
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    const role = dentry.inode.getRole(proc.uid, proc.gid);
    if (role != .user) return errorFromE(.PERM);

    dentry.changePermissions(@enumFromInt(mode)) catch |err| return errorFromZig(err);

    return 0;
}

fn chown(path: [*:0]const u8, uid: u16, gid: u16) isize {
    trace.info("chown(0x{x}, {}, {})", .{@intFromPtr(path), uid, gid});
    return chownImpl(linux.AT.FDCWD, path, uid, gid, 0);
}

fn lchown(path: [*:0]const u8, uid: u16, gid: u16) isize {
    trace.info("lchown(0x{x}, {}, {})", .{@intFromPtr(path), uid, gid});
    return chownImpl(linux.AT.FDCWD, path, uid, gid, linux.AT.SYMLINK_NOFOLLOW);
}

fn fchown(fd: linux.fd_t, uid: u16, gid: u16) isize {
    trace.info("fchown({}, {}, {})", .{fd, uid, gid});
    return chownImpl(fd, undefined, uid, gid, linux.AT.EMPTY_PATH);
}

fn fchownAt(dir_fd: linux.fd_t, path: [*:0]const u8, uid: u16, gid: u16, flags: u32) isize {
    trace.info("fchownat({}, 0x{x}, {}, {}, 0x{x})", .{
        dir_fd, @intFromPtr(path), uid, gid, flags
    });
    return chownImpl(dir_fd, path, uid, gid, flags);
}

fn chownImpl(dir_fd: linux.fd_t, path: [*:0]const u8, uid: u16, gid: u16, flags: u32) isize {
    const proc = sys.Process.getCurrent();
    const dentry = fdAtLookup(
        proc, dir_fd, path, flags
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    const role = dentry.inode.getRole(proc.uid, proc.gid);
    if (role != .user) return errorFromE(.PERM);

    dentry.changeOwner(uid, gid) catch |err| return errorFromZig(err);

    return 0;
}

fn creat(path: [*:0]const u8, mode: linux.mode_t) isize {
    trace.info("creat(0x{x}, 0o{o})", .{@intFromPtr(path), mode});

    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    return openImpl(linux.AT.FDCWD, path, flags, mode);
}

fn dup(fd: linux.fd_t) isize {
    trace.info("dup({})", .{fd});
    if (fd < 0) return errorFromE(.BADF);

    const proc = sys.Process.getCurrent();
    const desc = proc.files.duplicate(@intCast(fd)) catch |err| return errorFromZig(err);

    log.debug("duplicated: {}", .{desc.idx});
    return desc.idx;
}

fn dup2(fd: linux.fd_t, new: linux.fd_t) isize {
    trace.info("dup2({}, {})", .{fd, new});
    return dupImpl(fd, new, false);
}

fn dup3(fd: linux.fd_t, new: linux.fd_t, flags: u32) isize {
    trace.info("dup3({}, {})", .{fd, new});

    const close_exec_flag: u32 = @bitCast(linux.O{ .CLOEXEC = true });
    const close_on_exec = if (flags == close_exec_flag) true else blk: {
        if (flags != 0) return errorFromE(.INVAL) else break :blk false;
    };

    return dupImpl(fd, new, close_on_exec);
}

fn dupImpl(fd: linux.fd_t, new: linux.fd_t, close_on_exec: bool) isize {
    if (fd < 0 or new < 0) return errorFromE(.BADF);
    if (fd == new) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const desc = proc.files.newDescriptorAt(
        @intCast(new), file, false
    ) catch |err| return errorFromZig(err);

    _ = proc.files.setCloseOnExec(desc.idx, close_on_exec);
    return desc.idx;
}

fn execve(path: [*c]const u8, args: ?[*:null][*c]const u8, envs: ?[*:null][*c]const u8) isize {
    trace.info("execve(0x{x}, 0x{x}, 0x{x})", .{
        @intFromPtr(path), @intFromPtr(args), @intFromPtr(envs)
    });

    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(args), vm.page_size) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(envs), vm.page_size) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();

    var ret_error: sys.exe.Error = undefined;
    const run_ctx: ?sys.exe.RunContext = blk: {
        const dentry = vfs.lookup(
            proc.root_dir, proc.work_dir, std.mem.span(path)
        ) catch |err| return errorFromZig(err);
        defer dentry.deref();

        const user_args = if (args) |argp| std.mem.span(argp) else &.{};
        const user_envs = if (envs) |envp| std.mem.span(envp) else &.{};
        log.debug("args: {}, envs: {}", .{user_args.len, user_envs.len});

        const kernel_args = sys.exe.copyArgs(@ptrCast(user_args)) catch return errorFromE(.NOMEM);
        defer sys.exe.freeArgs(kernel_args);
        const kernel_envs = sys.exe.copyArgs(@ptrCast(user_envs)) catch return errorFromE(.NOMEM);
        defer sys.exe.freeArgs(kernel_envs);

        var bin = sys.exe.Binary.init(dentry, proc) catch |err| return errorFromZig(err);
        defer bin.deinit();

        bin.load(kernel_args, kernel_envs) catch |err| {
            ret_error = err;
            if (proc.exe_file == null) break :blk null;
            return errorFromZig(err);
        };

        break :blk bin.data.run_ctx;
    };

    if (run_ctx == null) {
        @branchHint(.cold);
        log.warn("execve failed: {t}, kill: {f}", .{ret_error, proc});

        proc.terminate(1);
    }

    log.debug("loaded process: {f}", .{proc});
    sys.call.jumpThread(.linux_sysv, run_ctx.?);
}

fn exit(status: i32) void {
    trace.info("exit({})", .{status});

    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;
    const short_status: u8 = @truncate(@as(u32, @intCast(status)));

    proc.terminate(short_status);
}

fn exitGroup(status: i32) void {
    trace.info("exit_group({})", .{status});

    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;
    const short_status: u8 = @truncate(@as(u32, @intCast(status)));

    proc.terminate(short_status);
}

fn fcntl(fd: linux.fd_t, cmd: u32, arg: usize) isize {
    trace.info("fcntl({}, 0x{x}, 0x{x})", .{fd, cmd, arg});

    //const F_SETLEASE = 1024;
    //const F_GETLEASE = 1025;
    //const F_NOTIFY = 1026;
    //const F_DUPFD_QUERY = 1027;
    //const F_CREATED_QUERY = 1028;
    //const F_SETPIPE_SZ = 1031;
    //const F_GETPIPE_SZ = 1032;
    //const F_ADD_SEALS = 1033;
    //const F_GET_SEALS = 1034;
    //const F_GET_RW_HINT = 1035;
    //const F_SET_RW_HINT = 1036;
    //const F_GET_FILE_RW_HINT = 1037;
    //const F_SET_FILE_RW_HINT = 1038;
    const F_DUPFD_CLOEXEC = 1030;

    if (fd < 0) return errorFromE(.BADF);

    const proc = sys.Process.getCurrent();
    const handle = proc.files.getHandle(@intCast(fd)) orelse return errorFromE(.BADF);
    const file = handle.get().?;

    if (!file.get()) return errorFromE(.BADF);
    defer file.deref();

    switch (cmd) {
        linux.F.DUPFD => {
            const desc = proc.files.newDescriptorAt(
                @truncate(arg), file, true
            ) catch |err| return errorFromZig(err);
            return desc.idx;
        },
        linux.F.GETFD => return @intFromBool(handle.closeOnExec()),
        linux.F.SETFD => handle.setCloseOnExec((arg & 1) != 0),
        linux.F.GETFL => {
            const flags: linux.O = .{
                .ACCMODE = switch (file.perm) {
                    .w    => .WRONLY,
                    .rw   => .RDWR,
                    .wx   => .WRONLY,
                    .rwx  => .RDWR,
                    else  => .RDONLY
                },
                .CLOEXEC = handle.closeOnExec(),
            };
            return @as(u32, @bitCast(flags));
        },
        linux.F.SETFL => return fcntlSetFileFlags(proc, handle, arg),
        F_DUPFD_CLOEXEC => {
            const desc = proc.files.newDescriptorAt(
                @truncate(arg), file, true
            ) catch |err| return errorFromZig(err);

            _ = proc.files.setCloseOnExec(desc.idx, true);
            return desc.idx;
        },
        else => return errorFromE(.INVAL)
    }

    return 0;
}

fn fcntlSetFileFlags(proc: *sys.Process, handle: *sys.Process.FileTable.Handle, arg: usize) isize {
    const flags: linux.O = @bitCast(@as(u32, @truncate(arg)));
    const perm: vfs.Permissions = switch (flags.ACCMODE) {
        .WRONLY => .w,
        .RDWR   => .rw,
        else    => .r
    };

    const file = handle.get().?;
    const inode = file.dentry.inode;
    const role = inode.getRole(proc.uid, proc.gid);
    if (!file.dentry.inode.checkAccess(perm, role)) return errorFromE(.ACCES);

    file.perm = perm;
    handle.setCloseOnExec(flags.CLOEXEC);

    return 0;
}

fn fdAtGet(proc: *sys.Process, fd: linux.fd_t) ?*vfs.Dentry {
    if (fd == linux.AT.FDCWD) {
        proc.work_dir.ref();
        return proc.work_dir;
    } else if (fd < 0) return null;

    const file = proc.files.get(@intCast(fd)) orelse return null;
    defer file.deref();

    file.dentry.ref();
    return file.dentry;
}

fn fdAtGetIfRelative(proc: *sys.Process, fd: linux.fd_t, path: [*:0]const u8) vfs.Error!?*vfs.Dentry {
    if (path[0] == '/') return null;
    return fdAtGet(proc, fd) orelse return error.BadFileDescriptor;
}

fn fdAtLookup(proc: *sys.Process, dir_fd: linux.fd_t, path: [*:0]const u8, flags: u32) vfs.Error!*vfs.Dentry {
    if ((flags & linux.AT.EMPTY_PATH) != 0) {
        return fdAtGet(proc, dir_fd) orelse return error.BadFileDescriptor;
    }

    try validateMemoryArgs(@intFromPtr(path), sys.limits.max_path);

    const at_dir = try fdAtGetIfRelative(proc, dir_fd, path);
    defer if (at_dir) |d| d.deref();

    const slice = std.mem.span(path);
    if ((flags & linux.AT.SYMLINK_NOFOLLOW) != 0) {
        return lookupSymLink(proc.root_dir, at_dir, slice);
    }

    return vfs.lookup(proc.root_dir, at_dir, slice);
}

fn lookupSymLink(root: ?*vfs.Dentry, dir: ?*vfs.Dentry, path: []const u8) vfs.Error!*vfs.Dentry {
    const dir_path = path[0..(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)];

    return if (dir_path.len > 0) blk: {
        const parent = try vfs.lookup(root, dir, dir_path);
        if (dir_path.len + 1 >= path.len) return parent;

        defer parent.deref();
        break :blk parent.lookup(path[dir_path.len + 1..]) orelse return error.NoEnt;
    } else try vfs.lookupRaw(root, dir, path, false);
}

fn stat(path: [*:0]const u8, stats: *linux.Stat) isize {
    trace.info("stat(0x{x}, 0x{x})", .{@intFromPtr(path), @intFromPtr(stats)});
    return statImpl(linux.AT.FDCWD, path, stats, 0);
}

fn lstat(path: [*:0]const u8, stats: *linux.Stat) isize {
    trace.info("lstat(0x{x}, 0x{x})", .{@intFromPtr(path), @intFromPtr(stats)});
    return statImpl(linux.AT.FDCWD, path, stats, linux.AT.SYMLINK_NOFOLLOW);
}

fn fstat(fd: linux.fd_t, stats: *linux.Stat) isize {
    trace.info("fstat({}, 0x{x})", .{fd, @intFromPtr(stats)});
    return statImpl(fd, undefined, stats, linux.AT.EMPTY_PATH);
}

fn fstatAt(fd: linux.fd_t, path: [*:0]const u8, stats: *linux.Stat, flags: u32) isize {
    trace.info("fstatat64({}, 0x{x}, 0x{x}, 0x{x})", .{fd, @intFromPtr(path), @intFromPtr(stats), flags});
    return statImpl(fd, path, stats, flags);
}

fn statImpl(fd: linux.fd_t, path: [*:0]const u8, stats: *linux.Stat, flags: u32) isize {
    validateMemoryArgs(@intFromPtr(stats), @sizeOf(linux.Stat)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const dentry = fdAtLookup(
        proc, fd, path, flags
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    const inode = dentry.inode;

    inode.rw_sem.readLock();
    defer inode.rw_sem.readUnlock();

    const inode_type: u32 = switch (inode.type) {
        .unknown        => 0,
        .regular_file   => linux.S.IFREG,
        .directory      => linux.S.IFDIR,
        .char_device    => linux.S.IFCHR,
        .block_device   => linux.S.IFBLK,
        .fifo           => linux.S.IFIFO,
        .socket         => linux.S.IFSOCK,
        .symbolic_link  => linux.S.IFLNK,
    };

    const block_size,
    const dev_num = switch (dentry.meta.fs) {
        .super => blk: {
            const super = dentry.getSuper();
            const dev_num = super.part.dev_file.num;
            break :blk .{ super.block_size, @as(linux.dev_t, dev_num.major) << 20 | dev_num.minor };
        },
        else => .{ 512, 0 },
    };

    stats.* = .{
        .dev = dev_num,
        .ino = inode.index,
        .mode = inode_type | inode.perm,
        .nlink = inode.links_num,
        .uid = inode.uid,
        .gid = inode.gid,
        .rdev = 0,
        .size = @intCast(inode.size),
        .blksize = block_size,
        .blocks = @intCast((inode.size + 511) / 512),
        // FIXME: Check if this code is correct
        .atim = .{
            .sec =  @intCast(inode.access_time_sec),
            .nsec = inode.access_time_ns,
        },
        .mtim =  .{
            .sec = @intCast(inode.modify_time_sec),
            .nsec = inode.modify_time_ns,
        },
        .ctim =  .{
            .sec = @intCast(inode.create_time_sec),
            .nsec = inode.create_time_ns,
        },
        .__pad0 = undefined,
        .__unused = undefined,
    };

    if (
        (dentry.inode.type == .block_device or
        dentry.inode.type == .char_device) and
        dentry.getFileSystem() == vfs.devfs.getFs()
    ) {
        const dev_file = vfs.devfs.DevFile.fromDentry(dentry);
        stats.rdev = (@as(linux.dev_t, dev_file.num.major) << 8) | dev_file.num.minor;
    }

    return 0;
}

fn link(old_path: [*:0]const u8, new_path: [*:0]const u8) isize {
    trace.info("link(0x{x}, 0x{x})", .{@intFromPtr(old_path), @intFromPtr(new_path)});
    return linkImpl(linux.AT.FDCWD, old_path, linux.AT.FDCWD, new_path, linux.AT.SYMLINK_FOLLOW);
}

fn linkAt(
    old_dir_fd: linux.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: linux.fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) isize {
    trace.info("linkat(0x{x}, 0x{x})", .{@intFromPtr(old_path), @intFromPtr(new_path)});
    return linkImpl(old_dir_fd, old_path, new_dir_fd, new_path, flags);
}

fn linkImpl(
    old_dir_fd: linux.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: linux.fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) isize {
    validateMemoryArgs(@intFromPtr(new_path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const tmp_flags = if ((flags & linux.AT.SYMLINK_FOLLOW) != 0) flags else flags | linux.AT.SYMLINK_NOFOLLOW;
    const target = fdAtLookup(
        proc, old_dir_fd, old_path, tmp_flags
    )  catch |err| return errorFromZig(err);
    defer target.deref();

    if (target.inode.type == .directory) return errorFromE(.ISDIR);

    const new_dir = fdAtGetIfRelative(proc, new_dir_fd, new_path)  catch return errorFromE(.BADF);
    defer if (new_dir) |d| d.deref();

    const create_path = createFileGetPath(
        proc, new_dir orelse proc.root_dir, std.mem.span(new_path)
    ) catch |err| return errorFromZig(err);
    defer create_path.deref();

    log.debug("create hard link: {f}/{s} (inode {}, original: {f})", .{
        create_path.parent_dir.relativePath(proc.root_dir),
        create_path.base_name,
        target.inode.index,
        target.relativePath(proc.root_dir),
    });

    const hard_link = create_path.parent_dir.createLink(
        create_path.base_name, target.inode
    ) catch |err| return errorFromZig(err);
    defer hard_link.deref();

    std.debug.assert(hard_link.inode == target.inode);
    log.debug("links: {}, refs: {}", .{hard_link.inode.links_num, hard_link.inode.ref_count.count()});

    return 0;
}

fn symlink(target: [*:0]const u8, link_path: [*:0]const u8) isize {
    trace.info("symlink(0x{x}, 0x{x})", .{@intFromPtr(target), @intFromPtr(link_path)});
    return symlinkImpl(linux.AT.FDCWD, target, link_path);
}

fn symlinkAt(dir_fd: linux.fd_t, target: [*:0]const u8, link_path: [*:0]const u8) isize {
    trace.info("symlinkat({}, 0x{x}, 0x{x})", .{
        dir_fd, @intFromPtr(target), @intFromPtr(link_path)
    });
    return symlinkImpl(dir_fd, target, link_path);
}

fn symlinkImpl(dir_fd: linux.fd_t, target: [*:0]const u8, link_path: [*:0]const u8) isize {
    validateMemoryArgs(@intFromPtr(target), sys.limits.max_path) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(link_path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const at_dir = fdAtGetIfRelative(
        proc, dir_fd, link_path
    ) catch return errorFromE(.BADF);
    defer if (at_dir) |d| d.deref();

    const path = std.mem.span(link_path);
    const content = std.mem.span(target);

    const dentry = createAnyFile(
        proc, at_dir orelse proc.root_dir,
        path, .symbolic_link,
        @intFromEnum(vfs.Permissions.rwx),
        .fromPtr(@ptrCast(@constCast(&content))),
    ) catch |err| return errorFromZig(err);
    dentry.deref();

    return 0;
}

fn futex(addr: *const anyopaque, op: linux.FUTEX_OP) isize {
    trace.info("futex(0x{x}, {any})", .{@intFromPtr(addr), op});
    validateMemoryArgs(@intFromPtr(addr), @sizeOf(u32)) catch return errorFromE(.FAULT);

    return 0;
}

fn getCwd(buf: [*c]u8, len: usize) isize {
    trace.info("getcwd(0x{x}, {})", .{@intFromPtr(buf), len});

    if (@intFromPtr(buf) == 0 or len == 0) return errorFromE(.INVAL);
    validateMemoryArgs(@intFromPtr(buf), len) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const path = proc.work_dir.relativePath(proc.root_dir);
    _ = std.fmt.bufPrint(buf[0..len], "{f}\x00", .{path}) catch return errorFromE(.RANGE);

    return @intCast(std.mem.len(buf));
}

fn getDentries(fd: linux.fd_t, buffer: [*c]u8, len: usize) isize {
    trace.info("getdents64({}, 0x{x}, {})", .{fd, @intFromPtr(buffer), len});

    if (fd < 0) return errorFromE(.INVAL);
    validateMemoryArgs(@intFromPtr(buffer), len) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const dir = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer dir.deref();

    const dentry = dir.dentry;
    if (dentry.inode.type != .directory) return errorFromE(.NOTDIR);

    var iter: DirectoryIterator = .init(dir.offset, buffer[0..len]);
    dentry.iterate(&iter.iter) catch |err| return errorFromZig(err);

    dir.offset = iter.iter.pos;
    return @intCast(iter.getReadedBytes(buffer));
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

fn getPid() usize {
    trace.info("getpid()", .{});

    const proc = sys.Process.getCurrent();
    return proc.id.value;
}

fn getParentPid() usize {
    trace.info("getppid()", .{});

    const proc = sys.Process.getCurrent();

    proc.ctrl.lock.lock();
    defer proc.ctrl.lock.unlock();

    if (proc.parent == proc.id) {
        @branchHint(.unlikely);
        return 0;
    }

    return proc.parent.value;
}

fn getProcGroup() isize {
    trace.info("getpgrp()", .{});

    const proc = sys.Process.getCurrent();
    return proc.group.value;
}

fn getProcByPid(pid: linux.pid_t) ?*sys.Process {
    return if (pid == 0) sys.Process.getCurrent() else sys.Process.findById(@intCast(pid));
}

fn getProcGroupById(pid: linux.pid_t) isize {
    trace.info("getpgid({})", .{pid});

    if (pid < 0) return errorFromE(.INVAL);
    const proc = getProcByPid(pid) orelse return errorFromE(.SRCH);

    // TODO: Fix race conditions on process?
    return proc.group.value;
}

fn getRandom(buffer: [*]u8, len: usize, flags: u32) isize {
    trace.info("getrandom(0x{x}, {}, 0x{x})", .{@intFromPtr(buffer), len, flags});

    validateMemoryArgs(@intFromPtr(buffer), len) catch return errorFromE(.FAULT);

    // TODO: Implement real /dev/random and /dev/urandom devices
    const seed = sys.time.getTime().toNs() ^ @intFromPtr(buffer);
    var rand = std.Random.Xoroshiro128.init(seed);
    rand.fill(buffer[0..len]);

    return 0;
}

fn getRobustList(pid: linux.pid_t, head: *?*RobustList.Head, size: *usize) isize {
    trace.info("get_robust_list({}, 0x{x}, 0x{x})", .{pid, @intFromPtr(head), @intFromPtr(size)});

    const proc = sys.Process.getCurrent();
    // TODO: Implement access to other processes by pid.
    if (pid != 0 and pid != proc.id.value) return errorFromE(.INVAL);

    validateMemoryPtr(@intFromPtr(head)) catch return errorFromE(.FAULT);
    validateMemoryPtr(@intFromPtr(size)) catch return errorFromE(.FAULT);

    // TODO: Complete futex implementation.
    const abi_data = sched.getCurrentTask().spec.user.abi_data.asPtr(AbiData).?;
    size.* = @sizeOf(RobustList.Head);
    head.* = abi_data.robust_list;

    return 0;
}

fn getTid() usize {
    trace.info("gettid()", .{});

    const proc = sys.Process.getCurrent();
    return proc.id.value;
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

fn seek(fd: linux.fd_t, offset: isize, whence: u8) isize {
    trace.info("lseek({}, 0x{x}, {})", .{fd, offset, whence});
    if (fd < 0) return errorFromE(.BADF);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    switch (file.dentry.inode.type) {
        .fifo,
        .socket,
        .unknown => return errorFromE(.SPIPE),
        else => {}
    }

    // TODO: Thread-safety
    const base = switch (whence & 0x3) {
        linux.SEEK.SET => 0,
        linux.SEEK.CUR => file.offset,
        linux.SEEK.END => file.dentry.inode.size,
        else => return errorFromE(.INVAL)
    };

    const new_offset = @as(isize, @intCast(base)) +% offset;
    if (
        (offset < 0 and (new_offset < 0 or new_offset > base)) or
        (offset >= 0 and (new_offset < base)) or
        (file.dentry.inode.type == .regular_file and new_offset > file.dentry.inode.size)
    ) return errorFromE(.INVAL);

    file.offset = @intCast(new_offset);
    return new_offset;
}

fn mkdir(path: [*:0]const u8, mode: linux.mode_t) isize {
    trace.info("mkdir(0x{x}, 0o{o})", .{@intFromPtr(path), mode});
    return mkdirImpl(linux.AT.FDCWD, path, mode);
}

fn mkdirAt(fd: linux.fd_t, path: [*:0]const u8, mode: linux.mode_t) isize {
    trace.info("mkdirat({}, 0x{x}, 0o{o})", .{fd, @intFromPtr(path), mode});
    return mkdirImpl(fd, path, mode);
}

fn mkdirImpl(fd: linux.fd_t, path: [*:0]const u8, mode: linux.mode_t) isize {
    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const at_dir = fdAtGetIfRelative(proc, fd, path) catch return errorFromE(.BADF);
    defer if (at_dir) |d| d.deref();

    const slice: []const u8 = std.mem.span(path);
    if (slice.len == 0) return errorFromE(.NOENT);

    const raw_path = if (slice[slice.len - 1] == '/') slice[0..slice.len - 1] else slice;
    const create_path = createFileGetPath(
        proc, at_dir orelse proc.root_dir, raw_path
    ) catch |err| return errorFromZig(err);
    defer create_path.deref();

    const name = create_path.base_name;
    if (name.len == 0 or
        (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.')))
    ) return errorFromE(.EXIST);

    log.debug("create dir: '{s}'", .{name});
    const new_dir = create_path.parent_dir.createFile(name, .directory, .{
        .uid = proc.uid, .gid = proc.gid, .perm = @truncate(mode & (~proc.umask))
    }) catch |err| return errorFromZig(err);

    new_dir.deref();
    return 0;
}

fn mmap(virt: usize, len: usize, prot: c_int, flags: linux.MAP, fd: linux.fd_t, offset: linux.off_t) usize {
    trace.info("mmap(0x{x}, 0x{x}, {}, {any}, {}, {});", .{virt, len, prot, flags, fd, offset});

    if (!std.mem.isAligned(virt, vm.page_size) or
        !vm.isUserVirtAddr(virt +| len) or
        @intFromEnum(flags.TYPE) == 0 or
        flags.SYNC or len == 0 or
        flags.NONBLOCK or flags.POPULATE or flags.LOCKED or
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

fn mremap(addr: usize, len: usize, new_len: usize, flags: linux.MREMAP, new_addr: usize) isize {
    trace.warn("mremap(0x{x}, 0x{x}, 0x{x}, {any}, 0x{x})", .{
        addr, len, new_len, flags, new_addr,
    });

    const proc = sys.Process.getCurrent();
    log.debug("remap: {f}", .{proc.addr_space});

    return errorFromE(.NOSYS);
}

fn munmap(virt: usize, len: usize) isize {
    trace.info("munmap(0x{x}, 0x{x})", .{virt, len});

    if (!std.mem.isAligned(virt, vm.page_size) or
        !vm.isUserVirtAddr(virt +| len) or len == 0
    ) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const pages = vm.bytesToPages(len);

    proc.addr_space.unmapRange(virt, pages) catch {
        @branchHint(.cold);
        log.warn("munmap failed: {f}, 0x{x}+0x{x}", .{proc, virt, len});
    };
    return 0;
}

fn open(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) isize {
    trace.info("open(0x{x}, {any}, 0x{x})", .{@intFromPtr(path), flags, mode});
    return openImpl(linux.AT.FDCWD, path, flags, mode);
}

fn openAt(dir_fd: linux.fd_t, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) isize {
    trace.info("openAt({}, 0x{x}, {any}, 0x{x})", .{dir_fd, @intFromPtr(path), flags, mode});
    return openImpl(dir_fd, path, flags, mode);
}

fn openImpl(dir_fd: linux.fd_t, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) isize {
    validateMemoryPtr(@intFromPtr(path)) catch return @intCast(errorFromE(.FAULT));

    const proc = sys.Process.getCurrent();
    if (proc.files.isFull()) return @intCast(errorFromE(.MFILE));

    // Always add execute permission to allow to map file pages with execute permission.
    const perm: vfs.Permissions = switch (flags.ACCMODE) {
        .RDONLY => .rx,
        .WRONLY => .wx,
        .RDWR   => .rwx,
    };

    const at_dir = fdAtGetIfRelative(proc, dir_fd, path) catch return errorFromE(.BADF);
    const dir = at_dir orelse proc.root_dir;
    defer if (at_dir) |d| d.deref();

    const path_slice = std.mem.span(path);
    const dentry = vfs.lookup(
        proc.root_dir, dir, path_slice
    ) catch |err| {
        if (err == error.NoEnt and flags.CREAT) return createAndOpenFile(
            proc, dir, path_slice, perm, mode
        );
        return @intCast(errorFromZig(err));
    };
    defer dentry.deref();

    if (flags.EXCL) return errorFromE(.EXIST);

    const inode = dentry.inode;
    if (inode.type == .directory and (flags.ACCMODE != .RDONLY or !flags.DIRECTORY)) return @intCast(errorFromE(.ISDIR));
    if (inode.type != .directory and flags.DIRECTORY) return @intCast(errorFromE(.NOTDIR));

    const role = inode.getRole(proc.uid, proc.gid);
    if (!inode.checkAccess(perm.remove(.x), role)) return @intCast(errorFromE(.ACCES));

    const desc = proc.files.open(dentry, perm) catch |err| {
        if (err == error.MaxSize) return @bitCast(errorFromE(.NFILE));
        return @bitCast(errorFromZig(err));
    };

    return desc.idx;
}

fn createFileGetPath(
    proc: *sys.Process,
    dir: *vfs.Dentry,
    path: []const u8,
) vfs.Error!vfs.CreatePath {
    const create_path = try vfs.resolveCreatePath(proc.root_dir, dir, path);
    errdefer create_path.deref();

    const parent_dir = create_path.parent_dir;
    const role = parent_dir.inode.getRole(proc.uid, proc.gid);
    if (!parent_dir.inode.checkAccess(.w, role)) return error.NoAccess;

    return create_path;
}

fn createAnyFile(
    proc: *sys.Process,
    dir: *vfs.Dentry,
    path: []const u8,
    @"type": vfs.Inode.Type,
    mode: linux.mode_t,
    fs_data: lib.AnyData,
) vfs.Error!*vfs.Dentry {
    const create_path = try createFileGetPath(proc, dir, path);
    defer create_path.deref();

    log.debug("create file: {f}/{s}, {t}, perm: 0o{o}", .{
        create_path.parent_dir.relativePath(proc.root_dir), create_path.base_name, @"type", mode
    });
    return create_path.parent_dir.createFileRaw(create_path.base_name, @"type", .{
        .uid = proc.uid,
        .gid = proc.gid,
        .perm = @truncate(mode & (~proc.umask))
    }, fs_data);
}

fn createAndOpenFile(
    proc: *sys.Process,
    dir: *vfs.Dentry,
    path: []const u8,
    perm: vfs.Permissions,
    mode: linux.mode_t,
) isize {
    const dentry = createAnyFile(
        proc, dir,
        path, .regular_file,
        mode, .{},
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    const desc = proc.files.open(dentry, perm) catch |err| {
        if (err == error.MaxSize) return @bitCast(errorFromE(.NFILE));
        return @bitCast(errorFromZig(err));
    };

    return desc.idx;
}

fn poll(fds: [*c]linux.pollfd, len: usize, timeout: i32) isize {
    trace.info("poll(0x{x}, {}, {})", .{@intFromPtr(fds), len, timeout});
    if (len > sys.limits.max_poll_fds) return errorFromE(.INVAL);

    validateMemoryArgs(
        @intFromPtr(fds), @sizeOf(linux.pollfd) * len
    ) catch return errorFromE(.FAULT);

    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;

    // Initialize poll caches
    const caches = vfs.File.Poll.Cache.getPool(&task.spec.user, @truncate(len)) catch return errorFromE(.NOMEM);
    var invalid: u32 = 0;

    for (caches, fds) |*cache, *fd| {
        fd.revents = 0;
        cache.file = proc.files.get(@intCast(fd.fd)) orelse {
            @branchHint(.unlikely);

            invalid += 1;
            fd.revents = linux.POLL.NVAL;

            continue;
        };
    }

    if (invalid == len) return 0;
    defer vfs.File.Poll.Cache.closePool(caches);

    // Timeout
    const end_time_ns =
        if (timeout < 0)
            std.math.maxInt(u64)
        else
            sys.time.getUpTimeNs() +| @as(u64, @intCast(timeout)) * std.time.ns_per_ms;

    // Polling
    var n: u32 = 0;
    while (true) {
        task.prepareForSleep();

        for (fds[0..len], caches[0..len]) |*fd, *cache| {
            const file = cache.file orelse continue;
            if (fd.events == 0 or fd.revents != 0) continue;

            const action: vfs.File.Poll.WaitAction = if (n == 0 and cache.entry.isRemovedFromQueue()) .enqueue else .none;
            const result = file.poll(&cache.entry, action) catch {
                fd.revents = linux.POLL.ERR;
                n += 1;

                continue;
            };

            const mask = fd.events | linux.POLL.ERR | linux.POLL.HUP;
            fd.revents = @as(i16, @bitCast(result.toLinux())) & mask;
            if (fd.revents != 0) n += 1;
        }

        if (n != 0) {
            task.canclePrepareForSleep();
            return n;
        }

        const timeout_ns = end_time_ns -| sys.time.getUpTimeNs();
        sched.getCurrent().doWaitTimeout(timeout_ns, true) catch |err| {
            return if (err == error.Interrupted) errorFromE(.INTR) else 0;
        };
    }

    return 0;
}

fn epollCreate(size: i32) isize {
    trace.info("epoll_create({})", .{size});

    if (size <= 0) return errorFromE(.INVAL);
    return epollCreateImpl(0);
}

fn epollCreate1(flags: u32) isize {
    trace.info("epoll_create1({})", .{flags});
    return epollCreateImpl(flags);
}

fn epollCreateImpl(flags: u32) isize {
    if ((flags | linux.EPOLL.CLOEXEC) != linux.EPOLL.CLOEXEC) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const epoll = vfs.Epoll.new() catch return errorFromE(.NOMEM);
    errdefer epoll.deref();

    const desc = proc.files.newDescriptor(epoll) catch |err| return errorFromZig(err);
    if ((flags & linux.EPOLL.CLOEXEC) != 0) _ = proc.files.setCloseOnExec(desc.idx, true);

    return desc.idx;
}

fn epollControl(epfd: linux.fd_t, op: u32, fd: linux.fd_t, event: ?*linux.epoll_event) isize {
    trace.info("epoll_ctl({}, {}, {}, 0x{x})", .{epfd, op, fd, @intFromPtr(event)});

    if (epfd < 0 or fd < 0) return errorFromE(.BADF);
    if (epfd == fd) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const epoll_file = proc.files.get(@intCast(epfd)) orelse return errorFromE(.BADF);
    defer epoll_file.deref();

    if (epoll_file.type != .epoll) return errorFromE(.INVAL);
    const epoll = vfs.Epoll.fromFile(epoll_file);

    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    if (
        file == epoll_file or
        file.dentry.inode.type == .directory or
        file.dentry.inode.type == .regular_file
    ) return errorFromE(.INVAL);

    switch (op) {
        linux.EPOLL.CTL_ADD => {
            const e = event orelse return errorFromE(.INVAL);
            const mask: vfs.File.Poll = .fromLinux(e.events);
            epoll.addEntry(file, mask, e.data.ptr) catch |err| return errorFromZig(err);
        },
        linux.EPOLL.CTL_DEL => epoll.removeEntry(file) catch return errorFromE(.NOENT),
        linux.EPOLL.CTL_MOD => {
            const e = event orelse return errorFromE(.INVAL);
            const mask: vfs.File.Poll = .fromLinux(e.events);
            epoll.modifyEntry(file, mask, e.data.ptr) catch return errorFromE(.NOENT);
        },
        else => return errorFromE(.INVAL),
    }

    return 0;
}

fn epollWait(
    epfd: linux.fd_t, events: [*]linux.epoll_event,
    len: i32, timeout: i32,
) isize {
    trace.info("epoll_pwait2({}, 0x{x}, {}, {})", .{epfd, @intFromPtr(events), len, timeout});

    const timeout_ns: u64 = if (timeout < 0) std.math.maxInt(u64) else @intCast(timeout * std.time.ns_per_ms);
    return epollWaitImpl(epfd, events, len, timeout_ns, null);
}

fn epollPwait(
    epfd: linux.fd_t,
    events: [*]linux.epoll_event,
    len: i32,
    timeout: i32,
    sigmask: ?*const linux.sigset_t,
) isize {
    trace.info("epoll_pwait2({}, 0x{x}, {}, {}, 0x{x})", .{
        epfd, @intFromPtr(events), len, timeout, @intFromPtr(sigmask)
    });

    const timeout_ns: u64 = if (timeout < 0) std.math.maxInt(u64) else @intCast(timeout * std.time.ns_per_ms);
    return epollWaitImpl(epfd, events, len, timeout_ns, sigmask);
}

fn epollPwait2(
    epfd: linux.fd_t,
    events: [*]linux.epoll_event,
    len: i32,
    timeout: ?*const linux.timespec,
    sigmask: ?*const linux.sigset_t,
) isize {
    trace.info("epoll_pwait2({}, 0x{x}, {}, 0x{x}, 0x{x})", .{
        epfd, @intFromPtr(events), len, @intFromPtr(timeout), @intFromPtr(sigmask)
    });

    const timeout_ns: u64 = if (timeout) |t| blk: {
        validateMemoryArgs(@intFromPtr(t), @sizeOf(linux.timespec)) catch return errorFromE(.FAULT);
        if (t.sec < 0 or t.nsec < 0 or t.nsec >= std.time.ns_per_s) return errorFromE(.INVAL);

        break :blk @intCast((t.sec * std.time.ns_per_s) + t.nsec);
    } else std.math.maxInt(u64);

    return epollWaitImpl(epfd, events, len, timeout_ns, sigmask);
}

fn epollWaitImpl(
    epfd: linux.fd_t,
    events: [*]linux.epoll_event,
    len: i32,
    timeout_ns: u64,
    sigmask: ?*const linux.sigset_t,
) isize {
    if (epfd < 0) return errorFromE(.BADF);
    if (len <= 0) return errorFromE(.INVAL);

    const num: u32 = @intCast(len);
    validateFileMemoryArgs(epfd, @intFromPtr(events), num * @sizeOf(linux.epoll_event)) catch return errorFromE(.FAULT);

    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;

    const file = proc.files.get(@intCast(epfd)) orelse return errorFromE(.BADF);
    const epoll = if (file.type == .epoll) vfs.Epoll.fromFile(file) else return errorFromE(.BADF);

    // Set sigmask
    const old_sigmask = if (sigmask) |s| blk: {
        validateMemoryArgs(@intFromPtr(s), @sizeOf(linux.sigset_t)) catch return errorFromE(.FAULT);
        const old_sigmask = task.spec.user.sig_mask;
        task.spec.user.sig_mask.mask = @truncate(s[0]);

        break :blk old_sigmask;
    } else undefined;
    defer if (sigmask != null) {
        task.spec.user.sig_mask = old_sigmask;
        proc.deliverPendingSignals();
    };

    return epoll.wait(task, events[0..num], timeout_ns) catch |err| {
        if (err == error.Interrupted) return errorFromE(.INTR);
        return 0;
    };
}

fn pipe(fds: *[2]linux.fd_t) isize {
    trace.info("pipe(0x{x})", .{@intFromPtr(fds)});
    validateMemoryArgs(@intFromPtr(fds), @sizeOf([2]linux.fd_t)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const endpoints = vfs.Pipe.create(vm.page_size * 4) catch return errorFromE(.NOMEM);

    var descriptors: [2]sys.FileTable.Descriptor = .{
        .{ .idx = undefined, .file = endpoints[0] }, // read-end
        .{ .idx = undefined, .file = endpoints[1] }, // write-end
    };

    proc.files.newDescriptors(&descriptors) catch |err| {
        endpoints[0].deref();
        endpoints[1].deref();
        return errorFromZig(err);
    };
    fds.* = .{ @intCast(descriptors[0].idx), @intCast(descriptors[1].idx) };

    return 0;
}

// TODO: Support for 32-bit architectures
fn pread(fd: linux.fd_t, buf: [*]u8, len: usize, offset: u64) isize {
    trace.info("pread({}, 0x{x}, {}, 0x{x})", .{fd, @intFromPtr(buf), len, offset});

    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const readed = file.readAt(offset, buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(readed);
}

fn preadv(fd: linux.fd_t, iov: [*]posix.iovec, num: c_int, off: u64) isize {
    trace.info("preadv({}, 0x{x}, {}, {})", .{fd, @intFromPtr(iov), num, off});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var offset = off;
    var readed: usize = 0;
    for (iov[0..@intCast(num)]) |*io| {
        validateMemoryArgs(@intFromPtr(io.base), io.len) catch return errorFromE(.FAULT);
        readed += file.readAt(offset, io.base[0..io.len]) catch |err| return errorFromZig(err);
        offset += io.len;
    }

    return @intCast(readed);
}

fn prlimit64(pid: linux.pid_t, res: linux.rlimit_resource, new: ?*const linux.rlimit, old: ?*linux.rlimit) isize {
    trace.info("prlimit64({}, {}, 0x{x}, 0x{x})", .{pid, @intFromEnum(res), @intFromPtr(old), @intFromPtr(new)});

    const proc = sys.Process.getCurrent();
    // TODO: Implement access for other processes
    if (pid != 0 and pid != proc.id.value) return errorFromE(.PERM);
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
        .NPROC => {
            if (old) |o| {
                o.cur = sys.limits.max_process;
                o.max = sys.limits.max_process;
            }
            if (new) |n| {
                if (n.max > sys.limits.default_max_process) return errorFromE(.INVAL);
                sys.limits.max_process = @truncate(n.max);
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
                if (n.cur < vm.page_size) {
                    log.debug("set stack size: 0x{x}", .{n.cur});
                    return errorFromE(.INVAL);
                }
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
        .RSS => {
            if (old) |o| {
                o.cur = linux.RLIM.INFINITY;
                o.max = linux.RLIM.INFINITY;
            }
        },
        else => return errorFromE(.INVAL)
    }

    return 0;
}

fn pwrite(fd: linux.fd_t, buf: [*]const u8, len: usize, offset: u64) isize {
    trace.info("pwrite({}, 0x{x}, {}, {})", .{fd, @intFromPtr(buf), len, offset});

    validateFileMemoryArgs(fd, @intFromPtr(buf), len) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    const writen = file.writeAt(offset, buf[0..len]) catch |err| return errorFromZig(err);
    return @intCast(writen);
}

fn pwritev(fd: linux.fd_t, iov: [*]posix.iovec_const, num: c_int, off: u64) isize {
    trace.info("pwritev({}, 0x{x}, {}, {})", .{fd, @intFromPtr(iov), num, off});

    if (num <= 0) return errorFromE(.INVAL);
    validateFileMemoryArgs(
        fd, @intFromPtr(iov), @intCast(num * @sizeOf(posix.iovec_const))
    ) catch |err| return errorFromZig(err);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    var offset = off;
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

fn readLink(path: [*:0]const u8, buffer: [*]u8, len: usize) isize {
    trace.info("readlink(0x{x}, 0x{x}, {})", .{@intFromPtr(path), @intFromPtr(buffer), len});

    const proc = sys.Process.getCurrent();
    return readLinkImpl(null, proc, path, buffer[0..len]);
}

fn readLinkAt(dir_fd: linux.fd_t, path: [*:0]const u8, buffer: [*]u8, len: usize) isize {
    trace.info("readlinkat({}, 0x{x}, 0x{x}, {})", .{
        dir_fd, @intFromPtr(path), @intFromPtr(buffer), len
    });

    const proc = sys.Process.getCurrent();
    const dir = fdAtGet(proc, dir_fd) orelse return errorFromE(.BADF);
    defer dir.deref();

    return readLinkImpl(dir, proc, path, buffer[0..len]);
}

fn readLinkImpl(dir: ?*vfs.Dentry, proc: *sys.Process, path: [*:0]const u8, buffer: []u8) isize {
    if (buffer.len == 0) return errorFromE(.INVAL);

    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(buffer.ptr), buffer.len) catch return errorFromE(.FAULT);

    const at_dir = if (dir) |d| d else proc.work_dir;
    const slice = std.mem.span(path);

    const dentry = lookupSymLink(
        proc.root_dir, at_dir, slice
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    if (dentry.inode.type != .symbolic_link) return errorFromE(.INVAL);

    const size = dentry.readLink(buffer) catch |err| blk: {
        if (err == error.MaxSize) break :blk buffer.len;
        return errorFromZig(err);
    };

    return @intCast(size);
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

fn rmdir(path: [*:0]const u8) isize {
    trace.info("rmdir(0x{x})", .{@intFromPtr(path)});

    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);
    const proc = sys.Process.getCurrent();

    const slice = std.mem.span(path);
    const dentry = lookupSymLink(
        proc.root_dir, proc.work_dir, slice
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return rmdirImpl(proc, dentry);
}

fn rmdirImpl(proc: *sys.Process, dentry: *vfs.Dentry) isize {
    if (dentry.inode.type != .directory) return errorFromE(.NOTDIR);

    const mnt_point = dentry.getMountPoint();
    if (mnt_point.getRootDentry() == dentry) return errorFromE(.BUSY);

    const parent = dentry.parent;
    const role = parent.inode.getRole(proc.uid, proc.gid);
    if (!parent.inode.checkAccess(.w, role)) return errorFromE(.ACCES);

    dentry.unlink() catch |err| return errorFromZig(err);
    return 0;
}

fn setProcGroup(pid: linux.pid_t, pgid: linux.pid_t) isize {
    trace.info("setpgid({}, {})", .{pid, pgid});

    if (pid < 0 or pgid < 0) return errorFromE(.INVAL);
    const proc = getProcByPid(pid) orelse return errorFromE(.SRCH);

    proc.id.lock.lock();
    defer proc.id.lock.unlock();

    const real_pgid: u32 = if (pgid == 0) proc.id.value else @intCast(pgid);
    if (proc.group.value == real_pgid) return 0;

    if (proc.id.value == real_pgid) {
        const sid = blk: {
            const group = proc.group;

            group.lock.lockAtomic();
            defer group.lock.unlockAtomic();

            group.removeProcessFromGroupAtomic(proc);
            const sid = group.getSessionWeak().getId();
            sid.ref();

            break :blk sid;
        };
        defer sid.deref();
        sid.session.addGroup(proc.id);
    } else {
        const group = sys.Process.Id.lookup(real_pgid) orelse return errorFromE(.PERM);
        defer group.deref();

        if (group.getSessionWeakAtomic() != proc.group.getSessionWeakAtomic()) return errorFromE(.PERM);

        sys.Process.Id.processExitFromGroupAtomic(proc);
        group.addProcessToGroup(proc);
    }

    return 0;
}

const FdSet = std.bit_set.ArrayBitSet(usize, 1024);
const dummy_fd_set: FdSet = .initEmpty();

fn select(
    num: u32, read_fds: ?[*]usize, write_fds: ?[*]usize, except_fds: ?[*]usize,
    timeout: ?*linux.timeval
) isize {
    trace.info("select({}, 0x{x}, 0x{x}, 0x{x}, 0x{x})", .{
        num, @intFromPtr(read_fds), @intFromPtr(write_fds), @intFromPtr(except_fds), @intFromPtr(timeout)
    });
    validateMemoryArgs(@intFromPtr(timeout), @sizeOf(linux.timeval)) catch return errorFromE(.FAULT);
    return selectImpl(num, read_fds, write_fds, except_fds, timeout);
}

fn pselect(
    num: u32, read_fds: ?[*]usize, write_fds: ?[*]usize, except_fds: ?[*]usize,
    timeout: ?*const linux.kernel_timespec, sigmask: ?*const linux.sigset_t
) isize {
    trace.info("pselect({}, 0x{x}, 0x{x}, 0x{x}, 0x{x}, 0x{x})", .{
        num, @intFromPtr(read_fds), @intFromPtr(write_fds), @intFromPtr(except_fds),
        @intFromPtr(timeout), @intFromPtr(sigmask)
    });

    // TODO: Use sigmask here!
    var timeval: linux.timeval = undefined;
    const timeout_arg = if (timeout) |t| blk: {
        validateMemoryArgs(@intFromPtr(timeout), @sizeOf(linux.kernel_timespec)) catch return errorFromE(.FAULT);

        timeval.sec = @truncate(t.sec);
        timeval.usec = @divTrunc(t.nsec, std.time.ns_per_us);
        break :blk &timeval;
    } else null;

    return selectImpl(num, read_fds, write_fds, except_fds, timeout_arg);
}

fn selectImpl(
    num: u32, read_fds: ?[*]usize, write_fds: ?[*]usize, except_fds: ?[*]usize,
    timeout: ?*linux.timeval
) isize {
    if (num > FdSet.bit_length) return errorFromE(.INVAL);

    validateMemoryArgs(@intFromPtr(read_fds), @sizeOf(FdSet)) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(write_fds), @sizeOf(FdSet)) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(except_fds), @sizeOf(FdSet)) catch return errorFromE(.FAULT);

    // Initialize kernel-side bit sets
    const n = std.math.divCeil(u32, num, @bitSizeOf(usize)) catch unreachable;
    const buffer = vm.gpa.allocMany(usize, n * 3) orelse return errorFromE(.NOMEM);
    defer vm.gpa.free(buffer.ptr);

    @memset(buffer, 0);

    const in_set:  [*]usize = if (read_fds) |set| set else @constCast(&dummy_fd_set.masks);
    const out_set: [*]usize = if (write_fds) |set| set else @constCast(&dummy_fd_set.masks);
    const exp_set: [*]usize = if (except_fds) |set| set else @constCast(&dummy_fd_set.masks);

    const res_in:  [*]usize = buffer[0..n].ptr;
    const res_out: [*]usize = buffer[n..n * 2].ptr;
    const res_exp: [*]usize = buffer[n * 2..].ptr;

    const task = sched.getCurrentTask();
    const proc = task.spec.user.process;

    // Initialize poll caches
    const caches = vfs.File.Poll.Cache.getPool(&task.spec.user, num) catch return errorFromE(.NOMEM);
    defer vfs.File.Poll.Cache.closePool(caches);

    for (caches, 0..) |*cache, fd| {
        const i = fd / @bitSizeOf(usize);
        const mask: usize = @as(usize, 1) << @truncate(fd % @bitSizeOf(usize));

        const all_bits = in_set[i] | out_set[i] | exp_set[i];
        if ((all_bits & mask) == 0) continue;

        cache.file = proc.files.get(@truncate(fd)) orelse {
            @branchHint(.cold);
            continue;
        };
    }

    // Timeout
    const end_time_ns = if (timeout) |t| (
        sys.time.getUpTimeNs() +|
        (@as(u64, @intCast(t.sec)) * std.time.ns_per_s) +|
        (@as(u64, @intCast(t.usec)) * std.time.ns_per_us)
    ) else std.math.maxInt(u64);

    defer if (timeout) |t| {
        const remain_ns = end_time_ns -| sys.time.getUpTimeNs();
        const remain_sec = remain_ns / std.time.ns_per_s;
        const remain_us = (remain_ns % std.time.ns_per_s) / std.time.ns_per_us;

        t.sec = @truncate(@as(i64, @intCast(remain_sec)));
        t.usec = @truncate(@as(i64, @intCast(remain_us)));
    };

    // Polling
    var fds: u32 = 0;
    while (true) {
        task.prepareForSleep();

        for (caches, 0..) |*cache, fd| {
            const file = cache.file orelse continue;
            const i = fd / @bitSizeOf(usize);
            const mask: usize = @as(usize, 1) << @truncate(fd % @bitSizeOf(usize));

            const action: vfs.File.Poll.WaitAction = if (fds == 0 and cache.entry.isRemovedFromQueue()) .enqueue else .none;
            const result = file.poll(&cache.entry, action) catch {
                if ((exp_set[i] & mask) != 0) {
                    res_exp[i] |= mask; fds += 1;
                }
                continue;
            };

            if (result.read_avail and (in_set[i] & mask) != 0) {
                res_in[i] |= mask; fds += 1;
            }
            if (result.may_write and (out_set[i] & mask) != 0) {
                res_out[i] |= mask; fds += 1;
            }
        }

        if (fds > 0) {
            task.canclePrepareForSleep();

            if (read_fds != null) @memcpy(in_set[0..n], res_in[0..n]);
            if (write_fds != null) @memcpy(out_set[0..n], res_out[0..n]);
            if (except_fds != null) @memcpy(exp_set[0..n], res_exp[0..n]);
            return fds;
        }

        const timeout_ns = end_time_ns -| sys.time.getUpTimeNs();
        sched.getCurrent().doWaitTimeout(timeout_ns, true) catch |err| {
            return if (err == error.Interrupted) errorFromE(.INTR) else 0;
        };
    }

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

fn setTidAddress(addr: usize) usize {
    trace.info("set_tid_address(0x{x})", .{addr});
    log.warn("{t} is not yet implemented", .{linux.SYS.set_tid_address});

    return sys.Process.getCurrent().id.value;
}

fn setHostName(name: [*:0]const u8, len: usize) isize {
    trace.info("sethostname(0x{x}, {})", .{@intFromPtr(name), len});

    if (len == 0 or len > linux.HOST_NAME_MAX) return errorFromE(.INVAL);
    validateMemoryArgs(@intFromPtr(name), len) catch return errorFromE(.FAULT);

    sys.limits.host_lock.lock();
    defer sys.limits.host_lock.unlock();

    sys.limits.host_name.items.len = len;
    @memcpy(sys.limits.host_name.items[0..len], name[0..len]);

    return 0;
}

fn sigAction(sig: u32, action: ?*const linux.k_sigaction, old_action: ?*linux.k_sigaction) isize {
    trace.info("rt_sigaction({}, 0x{x}, 0x{x})", .{sig, @intFromPtr(action), @intFromPtr(old_action)});

    if (sig >= sys.Process.Signal.num) return errorFromE(.INVAL);

    validateMemoryArgs(@intFromPtr(action), @sizeOf(linux.k_sigaction)) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(old_action), @sizeOf(linux.k_sigaction)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();

    proc.ctrl.lock.lock();
    defer proc.ctrl.lock.unlock();

    if (old_action) |old| {
        old.flags = 0;
        old.handler = @ptrFromInt(proc.ctrl.sig_handlers[sig].func_ptr);
        old.mask[0] = proc.ctrl.sig_mask.mask;
    }

    if (action) |act| {
        if ((act.flags & linux.SA.SIGINFO) != 0) {
            log.warn("SA_SIGINFO is not supported", .{});
            //return errorFromE(.INVAL);
        }

        proc.ctrl.sig_handlers[sig].func_ptr = @intFromPtr(act.handler);
    }

    return 0;
}

fn sigProcMask(how: u32, new_set: ?*const linux.sigset_t, old_set: ?*linux.sigset_t) isize {
    trace.info("rt_sigprocmask(0x{x}, 0x{x}, 0x{x})", .{how, @intFromPtr(new_set), @intFromPtr(old_set)});
    validateMemoryArgs(@intFromPtr(new_set), @sizeOf(linux.sigset_t)) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(old_set), @sizeOf(linux.sigset_t)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();

    proc.ctrl.lock.lock();
    defer proc.ctrl.lock.unlock();

    if (old_set) |old| old[0] = ~proc.ctrl.sig_mask.mask;
    if (new_set) |new| {
        const new_mask = switch (how) {
            linux.SIG.BLOCK => proc.ctrl.sig_mask.mask & ~new[0],
            linux.SIG.UNBLOCK => proc.ctrl.sig_mask.mask | new[0],
            linux.SIG.SETMASK => ~new[0],
            else => return errorFromE(.INVAL),
        };

        proc.ctrl.sig_mask.mask = @truncate(sys.Process.Signal.non_maskable_signals.mask | new_mask);
        proc.deliverPendingSignalsAtomic();
    }

    return 0;
}

fn sigReturn(ctx: *arch.syscall.Context, stack: usize) callconv(.c) isize {
    trace.info("rt_sigreturn(0x{x})", .{stack});

    log.info("sigreturn: 0x{x}, 0x{x}", .{@intFromPtr(ctx), stack});
    return sys.call.signalReturn(ctx, stack);
}

fn sigSuspend(new_set: ?*const linux.sigset_t) isize {
    trace.info("rt_sigsuspend(0x{x})", .{@intFromPtr(new_set)});
    validateMemoryArgs(@intFromPtr(new_set), @sizeOf(linux.sigset_t)) catch return errorFromE(.FAULT);

    return errorFromE(.INTR);
}

fn kill(pid: i32, sig: u32) isize {
    trace.info("kill({}, {})", .{pid, sig});

    if (sig >= sys.Process.Signal.num) return errorFromE(.INVAL);
    if (sig == 0) return 0;

    if (pid > 0) {
        const target = sys.Process.findById(@intCast(pid)) orelse return errorFromE(.SRCH);
        target.sendSignal(@enumFromInt(sig));
    } else if (pid == 0) {
        const proc = sys.Process.getCurrent();
        proc.group.sendSignalToGroup(@enumFromInt(sig));
    } else if (pid == -1) {
        // FIXME: Implement send signal to every process in the system
        // (to which caller have permissions to send signals)
        return errorFromE(.NOSYS);
    } else {
        const group = sys.Process.Id.lookup(@intCast(-pid)) orelse return errorFromE(.SRCH);
        defer group.deref();

        group.sendSignalToGroup(@intFromEnum(sig));
    }

    return 0;
}

fn tkill(tid: u32, sig: u32) isize {
    trace.info("tkill({}, {t})", .{tid, @as(sys.Process.Signal, @enumFromInt(sig))});
    // FIXME: Implement tkill
    return errorFromE(.NOSYS);
}

fn tgkill(tgid: u32, tid: u32, sig: u32) isize {
    trace.info("tgkill({}, {}, {t})", .{tgid, tid, @as(sys.Process.Signal, @enumFromInt(sig))});
    // FIXME: Implement tgkill
    return errorFromE(.NOSYS);
}

fn time(time_out: ?*linux.time_t) isize {
    trace.info("time(0x{x})", .{@intFromPtr(time_out)});

    const epoch = sys.time.getEpoch();
    if (time_out) |ptr| {
        validateMemoryPtr(@intFromPtr(time_out)) catch return errorFromE(.FAULT);
        ptr.* = @intCast(epoch);
    }

    return @intCast(epoch);
}

fn getTimeOfDay(value: *linux.timeval, zone: ?*linux.timezone) isize {
    trace.info("gettimeofday(0x{x}, 0x{x})", .{ @intFromPtr(value), @intFromPtr(zone) });

    validateMemoryArgs(@intFromPtr(value), @sizeOf(linux.timeval)) catch return errorFromE(.FAULT);
    if (zone != null) validateMemoryArgs(@intFromPtr(zone), @sizeOf(linux.timezone)) catch return errorFromE(.FAULT);

    const curr_time = sys.time.getTime();
    value.sec  = @intCast(@as(u32, @truncate(curr_time.sec)));
    value.usec = @intCast(curr_time.ns / std.time.ns_per_us);

    // TODO: Implement timezone.
    if (zone) |z| z.* = .{ .dsttime = 0, .minuteswest = 0 };

    return 0;
}

fn truncate(path: [*:0]const u8, length: i64) isize {
    trace.info("truncate(0x{x}, {})", .{@intFromPtr(path), length});

    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const slice = std.mem.span(path);

    const dentry = vfs.lookup(
        proc.root_dir, proc.work_dir, slice
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return truncateImpl(proc, dentry, length);
}

fn ftruncate(fd: linux.fd_t, length: i64) isize {
    trace.info("ftruncate({}, {})", .{fd, length});
    if (fd < 0) return errorFromE(.BADF);

    const proc = sys.Process.getCurrent();
    const file = proc.files.get(@intCast(fd)) orelse return errorFromE(.BADF);
    defer file.deref();

    file.validateAccess(.w) catch return errorFromE(.INVAL);

    file.dentry.ref();
    defer file.dentry.deref();

    return truncateImpl(proc, file.dentry, length);
}

fn truncateImpl(proc: *sys.Process, dentry: *vfs.Dentry, length: i64) isize {
    if (length < 0) return errorFromE(.INVAL);

    const inode = dentry.inode;
    const role = inode.getRole(proc.uid, proc.gid);

    if (!inode.checkAccess(.w, role)) return errorFromE(.ACCES);
    if (inode.type == .directory) return errorFromE(.ISDIR);
    if (inode.type != .regular_file) return 0;

    dentry.resize(@intCast(length)) catch |err| return errorFromZig(err);

    return 0;
}

fn umask(mask: u16) isize {
    trace.info("umask({})", .{mask});
    const proc = sys.Process.getCurrent();

    proc.ctrl.lock.lock();
    defer proc.ctrl.lock.unlock();

    const old_mask = proc.umask;
    proc.umask = mask & 0o777;

    return old_mask;
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

    sys.limits.host_lock.lock();
    defer sys.limits.host_lock.unlock();

    const nodename = sys.limits.host_name.items;
    @memcpy(buf.nodename[0..nodename.len], nodename);

    return 0;
}

fn utime(path: [*:0]const u8, times: ?*const UtimeBuffer) isize {
    trace.info("utime(0x{x}, 0x{x})", .{@intFromPtr(path), @intFromPtr(times)});

    const proc = sys.Process.getCurrent();
    if (times) |t| {
        validateMemoryArgs(@intFromPtr(times), @sizeOf(UtimeBuffer)) catch return errorFromE(.FAULT);
        if (t.acc_time < 0 or t.mod_time < 0) return errorFromE(.INVAL);

        const sys_times: [2]sys.time.Time = .{
            .{ .sec = @intCast(t.acc_time) },
            .{ .sec = @intCast(t.mod_time) },
        };
        return utimeImpl(proc, proc.work_dir, path, &sys_times);
    } 

    return utimeImpl(proc, proc.work_dir, path, null);
}

fn utimes(path: [*:0]const u8, times: ?*const [2]linux.timeval) isize {
    trace.info("utimes(0x{x}, 0x{x})", .{@intFromPtr(path), @intFromPtr(times)});

    const proc = sys.Process.getCurrent();
    if (times) |t| {
        validateMemoryArgs(@intFromPtr(times), @sizeOf([2]linux.timeval)) catch return errorFromE(.FAULT);
        if (t[0].sec < 0 or t[0].usec < 0 or t[1].sec < 0 or t[1].usec < 0) return errorFromE(.INVAL);

        const sys_times: [2]sys.time.Time = .{
            .{ .sec = @intCast(t[0].sec), .ns = @as(u32, @intCast(t[0].usec)) * std.time.ns_per_us },
            .{ .sec = @intCast(t[1].sec), .ns = @as(u32, @intCast(t[1].usec)) * std.time.ns_per_us },
        };
        return utimeImpl(proc, proc.work_dir, path, &sys_times);
    } 

    return utimeImpl(proc, proc.work_dir, path, null);
}

fn utimeNsAt(fd: linux.fd_t, path: [*:0]const u8, times: ?*const [2]linux.timespec, flags: u32) isize {
    trace.info("utimensat({}, 0x{}, 0x{}, 0x{x})", .{
        fd, @intFromPtr(path), @intFromPtr(times), flags
    });

    const proc = sys.Process.getCurrent();
    const dir = fdAtGet(proc, fd) orelse return errorFromE(.BADF);
    defer dir.deref();

    if (times) |t| {
        validateMemoryArgs(@intFromPtr(times), @sizeOf([2]linux.timeval)) catch return errorFromE(.FAULT);
        if (t[0].sec < 0 or t[0].nsec < 0 or t[1].sec < 0 or t[1].nsec < 0) return errorFromE(.INVAL);

        const sys_times: [2]sys.time.Time = .{
            .{ .sec = @intCast(t[0].sec), .ns = @intCast(t[0].nsec) },
            .{ .sec = @intCast(t[1].sec), .ns = @intCast(t[1].nsec) },
        };
        return utimeImpl(proc, dir, path, &sys_times);
    }

    return utimeImpl(proc, dir, path, null);
}

fn utimeImpl(proc: *sys.Process, dir: *vfs.Dentry, path: [*:0]const u8, times: ?*const [2]sys.time.Time) isize {
    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);
    // TODO: Implement support for UTIME_NOW, UTIME_OMIT

    const slice = std.mem.span(path);
    const dentry = vfs.lookup(
        proc.root_dir, dir, slice
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    const role = dentry.inode.getRole(proc.uid, proc.gid);
    if (!dentry.inode.checkAccess(.w, role) and proc.uid != dentry.inode.uid) return errorFromE(.ACCES);

    const acc_time,
    const mod_time = if (times) |t| .{
        t[0], t[1]
    } else blk: {
        const curr_time = sys.time.getTime();
        break :blk .{ curr_time, curr_time };
    };

    dentry.touch(acc_time, mod_time) catch |err| return errorFromZig(err);
    return 0;
}

fn unlink(path: [*:0]const u8) isize {
    trace.info("unlink(0x{x})", .{@intFromPtr(path)});
    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const slice = std.mem.span(path);
    const dentry = lookupSymLink(
        proc.root_dir,
        proc.work_dir,
        slice,
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return unlinkImpl(proc, dentry);
}

fn unlinkAt(dir_fd: linux.fd_t, path: [*:0]const u8, flags: u32) isize {
    trace.info("unlinkat({}, 0x{x}, 0x{x})", .{dir_fd, @intFromPtr(path), flags});

    validateMemoryArgs(@intFromPtr(path), sys.limits.max_path) catch return errorFromE(.FAULT);
    if (flags != 0 and flags != linux.AT.REMOVEDIR) return errorFromE(.INVAL);

    const proc = sys.Process.getCurrent();
    const dir = fdAtGet(proc, dir_fd) orelse return errorFromE(.BADF);
    defer dir.deref();

    if (
        (path[0] != '/' and (path[0] != '~' or path[1] != '/')) and
        dir.inode.type != .directory
    ) return errorFromE(.NOTDIR);

    const slice = std.mem.span(path);
    const dentry = lookupSymLink(
        proc.root_dir, dir, slice,
    ) catch |err| return errorFromZig(err);
    defer dentry.deref();

    return if (flags == linux.AT.REMOVEDIR)
            rmdirImpl(proc, dentry)
        else
            unlinkImpl(proc, dentry);
}

fn unlinkImpl(proc: *sys.Process, dentry: *vfs.Dentry) isize {
    if (dentry.inode.type == .directory) return errorFromE(.ISDIR);

    const parent = dentry.parent;
    const role = parent.inode.getRole(proc.uid, proc.gid);
    if (!parent.inode.checkAccess(.w, role)) return errorFromE(.ACCES);

    dentry.unlink() catch |err| return errorFromZig(err);
    return 0;
}

fn waitPid(pid: linux.pid_t, status: ?*i32, options: u32, usage: ?*linux.rusage) isize {
    trace.info("wait4({}, 0x{x}, 0x{x}, 0x{x})", .{pid, @intFromPtr(status), options, @intFromPtr(usage)});

    // TODO: Implement waiting for any process in group.
    if (pid < -1) return errorFromE(.INVAL);

    validateMemoryArgs(@intFromPtr(status), @sizeOf(i32)) catch return errorFromE(.FAULT);
    validateMemoryArgs(@intFromPtr(usage), @sizeOf(linux.rusage)) catch return errorFromE(.FAULT);

    const proc = sys.Process.getCurrent();
    const nowait = (options & linux.W.NOHANG) != 0;
    const id = if (pid == -1) blk: {
        break :blk proc.waitAnyChildExit(nowait) catch return errorFromE(.INTR);
    } orelse {
            // TODO: Fix it: check if there is no child for nowait
            return if (nowait) errorFromE(.AGAIN) else errorFromE(.CHILD);
    } else if (pid > 0) blk: {
        const id = sys.Process.Id.lookup(@intCast(pid)) orelse return errorFromE(.CHILD);
        const success = proc.waitChildExit(id) catch return errorFromE(.INTR);
        if (!success) return errorFromE(.CHILD);

        break :blk id;
    } else return errorFromE(.CHILD);
    defer id.deref();

    const stats = id.owner.stats.?;
    if (status) |s| s.* = (@as(u16, stats.exit_status) << @bitSizeOf(u8)) | @intFromEnum(stats.fault_signal);
    if (usage) |u| {
        log.warn("'rusage' argument is not implemented", .{});
        const rusage_size = @sizeOf(linux.rusage) - @sizeOf(@TypeOf(u.__reserved));
        @memset(std.mem.asBytes(u)[0..rusage_size], 0);

        const sys_time_sec: u31 = @truncate(stats.sys_time_ns / std.time.ns_per_s);
        const sys_time_us: u31 = @truncate((stats.sys_time_ns % std.time.ns_per_s) / std.time.ns_per_us);
        const user_time_sec: u31 = @truncate(stats.user_time_ns / std.time.ns_per_s);
        const user_time_us: u31 = @truncate((stats.user_time_ns % std.time.ns_per_s) / std.time.ns_per_us);

        u.stime = .{ .sec = sys_time_sec, .usec = sys_time_us };
        u.utime = .{ .sec = user_time_sec, .usec = user_time_us };
    }

    return id.value;
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
