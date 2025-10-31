//! # Process Structure

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const sched = @import("../sched.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.Process");
const limits = @import("limits.zig");
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();
const List = utils.List(Self);
const Node = List.Node;

const RbNode = utils.rb.Node;

const TaskList = sched.Task.UserSpecific.UList;
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

pub const alloc_config: vm.obj.AllocatorConfig = .{
    .allocator = .safe_oma,
    .wrapper = .listNode(Node)
};

var pid_counter: std.atomic.Value(Pid) = .init(0);

pub inline fn allocId() Pid {
    return pid_counter.fetchAdd(1, .release) + 1;
}

pub inline fn freeId(pid: Pid) void {
    _ = pid_counter.cmpxchgWeak(
        pid, pid - 1,
        .acquire, .monotonic
    );
}

pid: Pid,
flags: Flags = .{},

root_dir: *vfs.Dentry,
work_dir: *vfs.Dentry,

parent: *Self,
childs: List = .{},

exe_file: *vfs.File = undefined,
files: FileTable,

/// User id.
uid: u16 = 0,
// Group id.
gid: u16 = 0,

addr_space: *AddressSpace,

/// All tasks related to this process.
tasks: TaskList = .{},
/// Lock used to protect `childs` and `tasks`.
list_lock: utils.RwLock = .{},

/// Node structure used to put process into red-black tree.
rb_node: RbNode = .{},

pub fn init(
    stack_size: usize,
    root_dir: *vfs.Dentry, work_dir: *vfs.Dentry
) !Self {
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
    const self = vm.obj.new(Self) orelse return error.NoMemory;
    errdefer vm.obj.free(Self, self);

    self.* = try .init(stack_size, root_dir, work_dir);
    return self;
}

pub fn clone(self: *Self) !*Self {
    const new = vm.obj.new(Self) orelse return error.NoMemory;
    errdefer vm.obj.free(Self, new);

    const file_table = try self.files.clone();

    self.root_dir.ref();
    self.work_dir.ref();
    self.exe_file.ref();
    self.addr_space.ref();

    self.* = .{
        .pid = allocId(),
        .flags = .{ .clone = true },
        .root_dir = self.root_dir,
        .work_dir = self.work_dir,
        .parent = self,
        .exe_file = self.exe_file,
        .addr_space = self.addr_space,
        .files = file_table,
    };

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.childs.append(new.asNode());
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.childs.first == null);
    std.debug.assert(self.tasks.first == null);

    self.root_dir.deref();
    self.work_dir.deref();
    self.files.deinit();
    self.exe_file.deref();
    self.addr_space.deref();

    freeId(self.pid);
}

pub inline fn delete(self: *Self) void {
    self.deinit();
    vm.obj.free(Self, self);
}

pub inline fn asNode(self: *Self) *Node {
    return @fieldParentPtr("data", self);
}

pub inline fn fromRbNode(rb_node: *RbNode) *Self {
    return @fieldParentPtr("rb_node", rb_node);
}

pub inline fn getCurrent() *Self {
    const task = sched.getCurrentTask();
    return task.spec.user.process;
}

pub inline fn assignExecutable(self: *Self, exe_file: *vfs.File) void {
    exe_file.ref();
    self.exe_file = exe_file;
}

pub fn addChild(self: *Self, child: *Self) void {
    std.debug.assert(self.parent == self);

    child.parent = self;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.childs.append(child.asNode());
}

pub fn pushTask(self: *Self, task: *sched.Task) void {
    task.spec.user.process = self;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.tasks.prepend(&task.spec.user.node);
}

pub fn mmap(
    self: *Self, file: ?*vfs.File, virt: ?usize,
    page_offset: u32, pages: u32, map_flags: vm.MapFlags,
) vfs.Error!usize {
    const map_unit = vm.obj.new(
        AddressSpace.MapUnit
    ) orelse return error.NoMemory;
    errdefer vm.obj.free(AddressSpace.MapUnit, map_unit);

    const base = if (virt) |v| v else blk: {
        self.addr_space.map_lock.readLock();
        defer self.addr_space.map_lock.readUnlock();

        break :blk self.addr_space.heapAllocRegion(pages)
            orelse return error.NoMemory;
    };
    // TODO: improve heap alloc ?

    map_unit.init(
        file, base,
        page_offset, pages, map_flags
    );

    if (file) |f| try f.mmap(map_unit);

    self.addr_space.map_lock.writeLock();
    defer self.addr_space.map_lock.writeUnlock();

    try self.addr_space.map(map_unit);

    return map_unit.base();
}

pub inline fn pageFault(self: *Self, addr: usize, cause: vm.FaultCause) void {
    self.addr_space.pageFault(addr, cause) catch {
        self.sendSignal(.SegFault);
    };
}

pub fn sendSignal(self: *Self, signal: Signal) void {
    // TODO: implement signals!
    log.warn(
        "unhandled signal: {s} -> PID: {}",
        .{ @tagName(signal), self.pid }
    );
}