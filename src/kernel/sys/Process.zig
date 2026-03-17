//! # Process Structure

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const linux = std.os.linux;
const log = std.log.scoped(.@"sys.Process");
const Teletype = @import("../dev.zig").classes.Teletype;
const limits = @import("limits.zig");
const lib = @import("../lib.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const Self = @This();
const SList = std.SinglyLinkedList;
const SNode = SList.Node;
const List = std.DoublyLinkedList;
const Node = List.Node;

const TaskList = sched.Task.Specific.User.UList;
const TaskNode = TaskList.Node;

pub const AddressSpace = @import("AddressSpace.zig");
pub const FileTable = @import("FileTable.zig");

pub const Flags = packed struct {
    clone: bool = false,
    terminate: bool = false,
};

pub const Signal = enum(u8) {
    pub const Handler = struct {
        func_ptr:   usize = 0,
        resume_ptr: usize = 0,
    };

    pub const num = blk: {
        var max = 0;
        for (std.enums.values(Signal)) |v| {
            const int = @intFromEnum(v);
            if (int > max) max = int;
        }

        break :blk max + 1;
    };

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
    WindowResize    = linux.SIG.WINCH,
};

/// Process identifier data structure.
/// 
/// It's used for 3 purposes at the same time:
/// - as process identifier;
/// - as process group structure;
/// - as session structure.
/// 
/// This is optimize memory managment and significantly simplify
/// atomic access to the structure data.
/// The id is shared between process, group and session.
pub const Id = struct {
    pub const Session = struct {
        tty: ?*Teletype = null,
        groups: SList = .{},

        pub inline fn setup(self: *Session) void {
            const id = self.getId();
            std.debug.assert(
                id.lock.isLocked() and self.groups.first == null or
                id.users.count() == 0
            );

            self.groups.prepend(&id.g_node);
        }

        pub fn removeGroup(self: *Session, group: *Id) void {
            const id = self.getId();
            defer id.deref();

            std.debug.assert(group.lock.isLocked() and id != group);

            {
                id.lock.lockAtomic();
                defer id.lock.unlockAtomic();

                self.groups.remove(&group.g_node);
                group.g_node.next = null;

                group.session.setRemoteSession(null);
            }

            if (self.tty) |tty| {
                tty.conf_lock.lockAtomic();
                defer tty.conf_lock.unlockAtomic();

                if (tty.sid != id) { @branchHint(.cold); return; }
                if (tty.foreground_group == group) tty.foreground_group = null;

                // If this group was the last in the session
                // and there are no other processes in the origin group - detach tty.
                if (id.isZombie() and id.p_node.next == null and self.groups.first == &id.g_node) {
                    @branchHint(.unlikely);

                    tty.sid = null;
                    id.deref();
                }
            }
        }

        pub fn addGroup(self: *Session, group: *Id) void {
            const id = self.getId();
            std.debug.assert(group.lock.isLocked() and id != group);

            id.lock.lockAtomic();
            defer id.lock.unlockAtomic();

            id.ref();
            self.groups.prepend(&group.g_node);
            group.session.setRemoteSession(self);
        }

        pub inline fn getId(self: *Session) *Id {
            return @fieldParentPtr("session", self);
        }

        fn leaderExit(self: *Session) void {
            std.debug.assert(self.getId().lock.isLocked());

            if (self.tty) |tty| {
                tty.detachSession();
                self.tty = null;
            }
        }

        inline fn setRemoteSession(self: *Session, remote: ?*Session) void {
            self.tty = @ptrCast(remote);
        }

        inline fn getRemoteSession(self: *Session) *Session {
            return @ptrCast(self.tty.?);
        }
    };

    const Waiter = struct {
        entry: sched.WaitQueue.Entry,
        notifier: ?*Id = null,

        inline fn init() Waiter {
            return .{ .entry = sched.getCurrent().initWait() };
        }

        inline fn fromNode(node: *sched.WaitQueue.QNode) *Waiter {
            const entry: *sched.WaitQueue.Entry = @fieldParentPtr("node", node);
            return @fieldParentPtr("entry", entry); 
        }
    };

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    const RbNode = lib.rb.Node;

    var base: std.atomic.Value(u32) = .init(1);
    var rb_tree: lib.rb.Tree(compare, keyCompare) = .{};
    var rb_lock: lib.sync.RwSemaphore = .{};

    value: u32,
    users: lib.atomic.RefCount(u32) = .{},

    rb_node: RbNode = .{},

    process: ?*Self = null,

    lock: lib.sync.Spinlock = .{},
    status: u8 = 0, // process exit status

    p_node: SList.Node = .{}, // processes list node
    g_node: SList.Node = .{}, // groups list node

    session: Session = .{},
    wait_queue: sched.WaitQueue = .{},

    pub fn new() ?*Id {
        const self = vm.auto.alloc(Id) orelse return null;
        self.* = .{ .value = base.fetchAdd(1, .release) };

        rb_lock.writeLock();
        defer rb_lock.writeUnlock();

        while (rb_tree.insert(&self.rb_node)) |_| {
            @branchHint(.unlikely);
            self.value = base.fetchAdd(1, .release);

            if (self.value >= sys.limits.max_process) {
                @branchHint(.cold);

                vm.auto.free(Id, self);
                return null;
            }
        }

        return self;
    }

    pub fn delete(self: *Id) void {
        std.debug.assert(self.users.count() == 0);
        {
            rb_lock.writeLock();
            defer rb_lock.writeUnlock();

            rb_tree.remove(&self.rb_node);
        }

        var tmp_value = base.load(.acquire);
        while (true) {
            if (self.value >= tmp_value) break;
            if (base.cmpxchgWeak(
                tmp_value, self.value,
                .release, .monotonic
            )) |value| tmp_value = value;
        }

        vm.auto.free(Id, self);
    }

    pub inline fn ref(self: *Id) void {
        self.users.inc();
    }

    pub fn deref(self: *Id) void {
        if (!self.users.put()) return;

        log.warn("delete id: {}", .{self.value});
        std.debug.assert(
            self.process == null and
            self.g_node.next == null and
            self.p_node.next == null and
            self.session.tty == null and
            self.session.groups.first == &self.g_node
        );

        self.delete();
    }

    pub fn lookup(id: u32) ?*Id {
        rb_lock.readLock();
        defer rb_lock.readUnlock();

        const node = rb_tree.lookup(id) orelse return null;
        const pid = fromRbNode(node);

        return if (pid.users.get()) pid else null;
    }

    pub fn addProcessToGroup(group: *Id, process: *sys.Process) void {
        std.debug.assert(process.group != group);

        group.lock.lock();
        defer group.lock.unlock();

        process.id.lock.lockAtomic();
        defer process.id.lock.unlockAtomic();

        if (process.flags.terminate) {
            @branchHint(.cold);
            return;
        }

        std.debug.assert(process.id.p_node.next == null);
        process.group = group;
        group.p_node.insertAfter(&process.id.p_node);
        group.users.inc();
    }

    pub fn removeProcessFromGroup(group: *Id, process: *sys.Process) void {
        std.debug.assert(
            process.id != group and
            process.group == group and
            process.id.lock.isLocked()
        );

        group.lock.lockAtomic();
        defer group.lock.unlockAtomic();

        group.removeProcessFromGroupAtomic(process);
    }

    pub fn removeProcessFromGroupAtomic(group: *Id, process: *sys.Process) void {
        defer group.deref();

        group.getProcessList().remove(&process.id.p_node);
        process.id.p_node.next = null;
        process.group = process.id;

        // If it was the last process in the group, we must remove group from session.
        if (group.isZombie() and group.p_node.next == null) {
            @branchHint(.unlikely);

            if (group.isSessionOwner()) return;
            group.session.getRemoteSession().removeGroup(group);
        }
    }

    pub inline fn sendSignalToGroup(group: *Id, signal: Signal) void {
        group.lock.lock();
        defer group.lock.unlock();

        group.sendSignalToGroupAtomic(signal);
    }

    pub fn sendSignalToGroupAtomic(group: *Id, signal: Signal) void {
        if (group.process) |p| p.sendSignalAtomic(signal);

        var node = group.p_node.next;
        while (node) |n| : (node = n.next) {
            const id = fromPNode(n);

            id.lock.lockAtomic();
            defer id.lock.unlockAtomic();

            if (id.process) |p| p.sendSignalAtomic(signal);
        }
    }

    pub inline fn getSessionWeak(group: *Id) *Session {
        std.debug.assert(group.lock.isLocked());
        return getSessionWeakAtomic(group);
    }

    pub fn getSessionWeakAtomic(group: *Id) *Session {
        if (group.isSessionOwner()) return &group.session;
        return group.session.getRemoteSession();
    }

    pub inline fn isZombie(self: *Id) bool {
        return self.process == null;
    }

    pub fn waitForGroupEvent(group: *Id) *Id {
        var waiter: Waiter = .init();
        {
            group.lock.lock();
            defer group.lock.unlock();
            group.wait_queue.push(&waiter.entry);
        }

        sched.getCurrent().wait();
        return waiter.notifier.?;
    }

    fn compare(left: *lib.rb.Node, right: *lib.rb.Node, _: ?*lib.rb.Node) std.math.Order {
        const lhs_id: *Id = fromRbNode(left);
        const rhs_id: *Id = fromRbNode(right);

        if (lhs_id.value == rhs_id.value) return .eq;
        return if (lhs_id.value < rhs_id.value) .lt else .gt;
    }

    fn keyCompare(left: *lib.rb.Node, key: anytype) std.math.Order {
        comptime std.debug.assert(@TypeOf(key) == u32);
        const lhs_id = fromRbNode(left);

        if (lhs_id.value == key) return .eq;
        return if (lhs_id.value < key) .lt else .gt;
    }

    inline fn getGroupLeader(group: *Id) ?*sys.Process {
        group.lock.lock();
        defer group.lock.unlock();

        return group.getGroupLeaderAtomic();
    }

    fn getGroupLeaderAtomic(group: *Id) ?*sys.Process {
        if (group.process) |p| return p;

        const node = group.p_node.findLast();
        const leader = fromPNode(node);

        return leader.process;
    }

    inline fn notifyGroup(group: *Id, notifier: *Self) void {
        group.lock.lock();
        defer group.lock.unlock();

        group.notifyGroupAtomic(notifier);
    }

    fn notifyGroupAtomic(group: *Id, notifier: *Self) void {
        var node = group.wait_queue.list.first.raw;
        while (node) |n| : (node = n.next) {
            const waiter = Id.Waiter.fromNode(n);

            waiter.notifier = notifier.id;
            notifier.id.ref();
        }

        sched.awakeAll(&group.wait_queue);
    }

    fn processAttach(self: *Id, process: *Self) void {
        std.debug.assert(process.id == self and self.users.count() == 0 and self.process == null);

        self.process = process;
        self.session.setup();
        self.ref();
    }

    fn processExit(self: *Id, status: u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        const proc = self.process.?;
        self.status = status;
        self.process = null;

        if (self != proc.group) {
            proc.group.notifyGroup(proc);
            proc.group.removeProcessFromGroup(proc);
        } else if (proc.group.isSessionOwner()) {
            proc.group.notifyGroupAtomic(proc);
            proc.group.session.leaderExit();
        } else if (self.p_node.next == null) {
            // This process is the group owner and there is no other process in group.
            const session = self.session.getRemoteSession();
            session.removeGroup(proc.group);
        }
    }

    inline fn isSessionOwner(self: *const Id) bool {
        return self.g_node.next == null;
    }

    inline fn getProcessList(group: *Id) *SList {
        return @ptrCast(&group.p_node);
    }

    inline fn fromRbNode(rb_node: *RbNode) *Id {
        return @fieldParentPtr("rb_node", rb_node);
    }

    inline fn fromPNode(p_node: *SNode) *Id {
        return @fieldParentPtr("p_node", p_node);
    }

    pub inline fn fromGNode(g_node: *SNode) *Id {
        return @fieldParentPtr("g_node", g_node);
    }
};

const Control = struct {
    const SignalSet = std.bit_set.IntegerBitSet(Signal.num);

    sig_mask: SignalSet = .initEmpty(),
    sig_handlers: [Signal.num]Signal.Handler = .{ Signal.Handler{} } ** Signal.num,

    lock: lib.sync.Spinlock = .{},
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

var init_proc: ?*Self = null;

id: *Id,
group: *Id,

/// User id.
uid: u16 = 0,
/// Group id.
gid: u16 = 0,

abi: sys.call.Abi = .linux_sysv,
flags: Flags = .{},
/// Exit status.
status: u8 = 0,

root_dir: *vfs.Dentry,
work_dir: *vfs.Dentry,

parent: *Self,
childs: List = .{},
node: Node = .{},

exe_file: ?*vfs.File = null,
interp_file: ?*vfs.File = null,
files: FileTable,

addr_space: *AddressSpace,
ctrl: Control = .{},

/// All tasks related to this process.
tasks: TaskList = .{},
/// Lock used to protect `childs` and `tasks`.
list_lock: lib.sync.RwLock = .{},

pub fn init(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) !Self {
    var files: FileTable = try .init(limits.default_max_open_files);
    errdefer files.deinit();

    const stack_pages: u16 = @truncate((stack_size + vm.page_size - 1) / vm.page_size);
    const addr_space = try AddressSpace.create(stack_pages);
    errdefer addr_space.delete();

    const id = Id.new() orelse return error.NoMemory;

    root_dir.ref();
    work_dir.ref();
    addr_space.ref();

    return .{
        .id = id,
        .group = id,
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

    self.id.processAttach(self);

    const task = try sched.Task.create(.{ .user = .{ .process = self } }, undefined);
    self.pushTask(task);

    if (init_proc == null) {
        @branchHint(.unlikely);
        init_proc = self;
    }
    return self;
}

pub fn clone(self: *Self) !*Self {
    const new = vm.auto.alloc(Self) orelse return error.NoMemory;
    errdefer vm.auto.free(Self, new);

    const id = Id.new() orelse return error.NoMemory;
    errdefer id.delete();
    const addr_space = try self.addr_space.cloneAndCopy();
    errdefer addr_space.delete();
    const file_table = try self.files.clone();
    errdefer file_table.deinit();

    if (self.exe_file) |f| f.ref();
    if (self.interp_file) |f| f.ref();

    self.root_dir.ref();
    self.work_dir.ref();
    addr_space.ref();

    new.* = .{
        .id = id,
        .group = id,
        .flags = .{ .clone = true },
        .root_dir = self.root_dir,
        .work_dir = self.work_dir,
        .parent = self,
        .exe_file = self.exe_file,
        .interp_file = self.interp_file,
        .addr_space = addr_space,
        .files = file_table,
    };

    const group = self.getGroup();
    defer group.deref();

    id.processAttach(new);
    group.addProcessToGroup(new);
    self.addChild(new);

    return new;
}

pub fn clear(self: *Self) *sched.Task {
    const task = self.terminateThreads().?;

    self.addr_space.clear();
    self.files.closeOnExecute();

    self.detachInterpreter();
    self.detachExecutable();
    self.flags = .{};

    return task;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.childs.first == null and self.id == self.group);

    var node = self.tasks.first;
    while (node) |n| {
        node = n.next;

        const task = sched.Task.Specific.User.fromNode(n).toTask();
        task.delete();
    }

    // Release pid only if we don't have a parent
    // else process should become a zombie.
    if (self.parent == self) {
        @branchHint(.unlikely);
        self.id.deref();
    }

    self.tasks.first = null;
    self.root_dir.deref();
    self.work_dir.deref();
    self.files.deinit();
    self.detachExecutable();
    self.detachInterpreter();
    self.addr_space.deref();
}

pub inline fn delete(self: *Self) void {
    self.deinit();
    vm.auto.free(Self, self);
}

pub inline fn findById(id: u32) ?*Self {
    const pid = Id.lookup(id) orelse return null;
    defer pid.deref();

    return pid.process;
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{f}:{}", .{self.exe_file.?.dentry.path(), self.id.value});
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

// Add newly created process as child.
pub fn addChild(self: *Self, child: *Self) void {
    std.debug.assert(self != child);

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    child.parent = self;
    self.childs.append(&child.node);
}

pub fn removeChild(self: *Self, child: *Self) void {
    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    // prevent race-condition
    if (child.parent != self) { @branchHint(.cold); return; }

    child.parent = child;
    self.childs.remove(&child.node);
}

pub fn detachAllChilds(self: *Self) void {
    if (self == init_proc) init_proc = null;

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();
    defer self.childs.first = null;

    var node = self.childs.first;
    while (node) |n| : (node = n.next) {
        const child = fromNode(n);
        child.parent = init_proc orelse blk: {
            @branchHint(.cold);

            init_proc = child; // check race-condition on setting init!
            break :blk child;
        };
    }
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

pub fn detachTask(self: *Self, task: *sched.Task) void {
    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    self.tasks.remove(&task.spec.user.node);
}

pub fn attachControlTerminal(self: *Self, tty: *Teletype) vfs.Error!void {
    self.id.lock.lock();
    defer self.id.lock.unlock();

    if (self.id != self.group) self.group.lock.lockAtomic();
    defer if (self.id != self.group) self.group.lock.unlockAtomic();

    const session = self.group.getSessionWeak();
    const sid = session.getId();
    if (sid == self.group) {
        try tty.attachSession(sid);
    } else {
        sid.lock.lockAtomic();
        defer sid.lock.unlockAtomic();

        try tty.attachSession(sid);
    }
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

pub inline fn getGroup(self: *Self) *Id {
    self.id.lock.lock();
    defer self.id.lock.unlock();

    const group = self.group;
    group.users.inc();

    return group;
}

pub fn spawnSession(self: *Self) void {
    std.debug.assert(self.group == self.id and !self.id.isSessionOwner());

    self.group.lock.lock();
    defer self.group.lock.unlock();

    const session = self.group.getSessionWeak();
    session.removeGroup(self.group);

    self.group.session.setup();
}

pub fn terminateThreads(self: *Self) ?*sched.Task {
    {
        self.ctrl.lock.lock();
        defer self.ctrl.lock.unlock();

        // TODO: Handle this case.
        if (self.flags.terminate) @panic("remote termination is not implemented");

        self.flags.terminate = true;
    }

    // TODO: Remote termination from other process or kernel thread!
    const task = sched.getCurrentTask();
    const proc = if (task.spec == .user) task.spec.user.process else null;
    if (proc != self) @panic("remote termination is not implemented");

    self.detachTask(task);
    if (self.tasks.first != null) @panic("remote termination is not implemented");

    return task;
}

/// Terminate process: kill all threads, detach childs to init, set exit status.
pub fn terminate(self: *Self, status: u8) void {
    std.debug.assert(getCurrent() == self);

    _ = self.terminateThreads();
    self.detachAllChilds();

    self.id.processExit(status);
    if (self.parent != self) self.parent.notifyEvent();
}

pub fn waitChildExit(self: *Self, nowait: bool) ?*Id {
    const proc = blk: { while (true) {
        self.id.lock.lock();
        {
            self.list_lock.writeLock();
            defer self.list_lock.writeUnlock();

            if (self.childs.first == null) {
                self.id.lock.unlock();
                return null;
            }

            var node = self.childs.first;
            while (node) |n| : (node = n.next) {
                const proc = fromNode(n);
                if (proc.isZombie()) {
                    self.id.lock.unlock();
                    self.childs.remove(&proc.node);

                    proc.parent = proc;
                    break :blk proc;
                }
            }
        }

        if (nowait) {
            @branchHint(.unlikely);
            self.id.lock.unlock();
            return null;
        }
        sched.waitUnlock(&self.id.wait_queue, &self.id.lock);
    }};

    const id = proc.id;
    vm.auto.free(Self, proc);

    return id;
}

pub fn waitEvent(self: *Self) void {
    self.id.lock.lock();
    sched.waitUnlock(&self.id.wait_queue, &self.id.lock);
}

pub fn notifyEvent(self: *Self) void {
    const parent = self.parent;

    parent.id.lock.lock();
    defer parent.id.lock.unlock();

    sched.awakeAll(&parent.id.wait_queue);
}

pub inline fn isZombie(self: *Self) bool {
    return self.id.isZombie();
}

pub fn sendSignal(self: *Self, signal: Signal) void {
    self.sendSignalAtomic(signal);
    sched.pause();
}

pub fn sendSignalAtomic(self: *Self, signal: Signal) void {
    // TODO: implement signals!
    log.warn("unhandled signal: {s} -> {f}", .{@tagName(signal), self});
}
