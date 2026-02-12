//! # Process Structure

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.Process");
const limits = @import("limits.zig");
const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();
const List = std.DoublyLinkedList;
const Node = List.Node;

const RbNode = lib.rb.Node;

const TaskList = sched.Task.Specific.User.UList;
const TaskNode = TaskList.Node;

/// Process identifier data type.
pub const Pid = u32;
pub const AddressSpace = @import("AddressSpace.zig");
pub const FileTable = @import("FileTable.zig");

pub const Flags = packed struct {
    clone: bool = false,
};

pub const Signal = enum(u8) {
    Abort           = linux.SIG.ABRT,
    Alarm           = linux.SIG.ALRM,
    BadSyscall      = linux.SIG.SYS,
    BrokenPipe      = linux.SIG.PIPE,
    BusError        = linux.SIG.BUS,
    Child           = linux.SIG.CHLD,
    Continue        = linux.SIG.CONT,
    CpuTimeout      = linux.SIG.XCPU,
    EmulatorTrap    = if (@hasDecl(linux.SIG, "EMT")) linux.SIG.EMT else 0,
    FileSizeLimit   = linux.SIG.XFSZ,
    Hangup          = linux.SIG.HUP,
    IllegalInstr    = linux.SIG.ILL,
    Interrupt       = linux.SIG.INT,
    Kill            = linux.SIG.KILL,
    Poll            = linux.SIG.POLL,
    PowerFail       = linux.SIG.PWR,
    ProfTimeout     = linux.SIG.PROF,
    Quit            = linux.SIG.QUIT,
    SegFault        = linux.SIG.SEGV,
    Stop            = linux.SIG.STOP,
    TerminalInput   = linux.SIG.TTIN,
    TerminalOutput  = linux.SIG.TTOU,
    TerminalStop    = linux.SIG.TSTP,
    Terminate       = linux.SIG.TERM,
    Trap            = linux.SIG.TRAP,
    Urgent          = linux.SIG.URG,
    User1           = linux.SIG.USR1,
    User2           = linux.SIG.USR2,
    VirtAlarm       = linux.SIG.VTALRM,
    WindowResize    = linux.SIG.WINCH
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

var pid_counter: std.atomic.Value(Pid) = .init(0);

pub inline fn allocId() Pid {
    return pid_counter.fetchAdd(1, .release) + 1;
}

pub inline fn freeId(pid: Pid) void {
    _ = pid_counter.cmpxchgStrong(
        pid, pid - 1,
        .acquire, .monotonic
    );
}

pid: Pid,
abi: sys.call.Abi = .linux_sysv,
flags: Flags = .{},

root_dir: *vfs.Dentry,
work_dir: *vfs.Dentry,

parent: *Self,
childs: List = .{},
node: Node = .{},

exe_file: ?*vfs.File = null,
interp_file: ?*vfs.File = null,
files: FileTable,

/// User id.
uid: u16 = 0,
// Group id.
gid: u16 = 0,

addr_space: *AddressSpace,

/// All tasks related to this process.
tasks: TaskList = .{},
/// Lock used to protect `childs` and `tasks`.
list_lock: lib.sync.RwLock = .{},

/// Node structure used to put process into red-black tree.
rb_node: RbNode = .{},

pub fn init(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) !Self {
    var files: FileTable = try .init(limits.default_max_open_files);
    errdefer files.deinit();

    const stack_pages: u16 = @truncate((stack_size + vm.page_size - 1) / vm.page_size);
    const addr_space = try AddressSpace.create(stack_pages);

    root_dir.ref();
    work_dir.ref();
    addr_space.ref();

    return .{
        .pid = allocId(),
        .root_dir = root_dir,
        .work_dir = work_dir,
        .parent = undefined,
        .files = files,
        .addr_space = addr_space,
    };
}

pub fn create(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) !*Self {
    const self = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer vm.auto.free(Self, self);

    self.* = try .init(stack_size, root_dir, work_dir);
    self.parent = self;
    errdefer self.deinit();

    const task = try sched.Task.create(.{ .user = .{ .process = self } }, undefined);
    self.pushTask(task);

    return self;
}

pub fn clone(self: *Self) !*Self {
    const new = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer vm.auto.free(Self, new);

    const addr_space = try self.addr_space.cloneAndCopy();
    const file_table = try self.files.clone();

    if (self.exe_file) |f| f.ref();
    if (self.interp_file) |f| f.ref();

    self.root_dir.ref();
    self.work_dir.ref();
    addr_space.ref();

    new.* = .{
        .pid = allocId(),
        .flags = .{ .clone = true },
        .root_dir = self.root_dir,
        .work_dir = self.work_dir,
        .parent = self,
        .exe_file = self.exe_file,
        .interp_file = self.interp_file,
        .addr_space = addr_space,
        .files = file_table,
    };

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.childs.append(&new.node);
    return new;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.childs.first == null);

    var node = self.tasks.first;
    while (node) |n| {
        node = n.next;

        const task = sched.Task.Specific.User.fromNode(n).toTask();
        task.delete();
    }

    if (self.parent != self) {
        @branchHint(.likely);
        self.parent.childs.remove(&self.node);
    }

    self.tasks.first = null;
    self.root_dir.deref();
    self.work_dir.deref();
    self.files.deinit();
    self.detachExecutable();
    self.detachInterpreter();
    self.addr_space.deref();

    freeId(self.pid);
}

pub inline fn delete(self: *Self) void {
    self.deinit();
    vm.auto.free(Self, self);
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn fromRbNode(rb_node: *RbNode) *Self {
    return @fieldParentPtr("rb_node", rb_node);
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{f}:{}", .{self.exe_file.?.dentry.path(), self.pid});
}

pub inline fn getMainTask(self: *Self) ?*sched.Task {
    const user = sched.Task.Specific.User.fromNode(self.tasks.first orelse return null);
    const specific: *sched.Task.Specific = @ptrCast(user);
    return @fieldParentPtr("spec", specific);
}

pub inline fn getCurrent() *Self {
    const task = sched.getCurrentTask();
    return task.spec.user.process;
}

pub inline fn assignExecutable(self: *Self, exe_file: *vfs.File) void {
    exe_file.ref();
    self.exe_file = exe_file;
}

pub inline fn assignInterpreter(self: *Self, interp_file: *vfs.File) void {
    interp_file.ref();
    self.interp_file = interp_file;
}

pub inline fn detachExecutable(self: *Self) void {
    const exe = self.exe_file orelse return;
    self.exe_file = null;
    exe.deref();
}

pub inline fn detachInterpreter(self: *Self) void {
    const interp = self.interp_file orelse return;
    self.interp_file = null;
    interp.deref();
}

pub fn addChild(self: *Self, child: *Self) void {
    std.debug.assert(self != child);

    child.parent = self;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.childs.append(&child.node);
}

pub fn removeChild(self: *Self, child: *Self) void {
    std.debug.assert(child.parent == self);

    child.parent = child;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.childs.remove(&child.node);
}

pub fn createTask(self: *Self) vm.Error!*sched.Task {
    const task = try sched.Task.create(
        .{ .user = .{ .process = self } }, undefined
    );

    self.pushTask(task);
    return task;
}

pub fn pushTask(self: *Self, task: *sched.Task) void {
    task.spec.user.process = self;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.tasks.prepend(&task.spec.user.node);
}

pub fn pageFault(self: *Self, address: usize, cause: vm.FaultCause) bool {
    const err = blk: {
        if (!vm.isUserVirtAddr(address)) break :blk error.InvalidArgs;
        self.addr_space.pageFault(address, cause) catch |err| break :blk err;

        return true;
    };

    log.debug("page fault failed: {s}, 0x{x} - {t}:\n\r\t{f}", .{
        @errorName(err), address, cause, self.addr_space
    });

    self.sendSignalAtomic(.SegFault);
    return false;
}

pub fn sendSignal(self: *Self, signal: Signal) void {
    self.sendSignalAtomic(signal);
    sched.pause();
}

pub fn sendSignalAtomic(self: *Self, signal: Signal) void {
    // TODO: implement signals!
    log.warn("unhandled signal: {s} -> {f}", .{@tagName(signal), self});
}
