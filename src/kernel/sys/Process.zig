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

pub const Flags = packed struct(u8) {
    clone: bool = false,
    terminate: bool = false,

    unused: u6 = 0,

    inline fn atomicSet(self: *Flags, mask: Flags) Flags {
        const old = @atomicRmw(u8, @as(*u8, @ptrCast(self)), .Or, @bitCast(mask), .release);
        return @bitCast(old);
    }

    inline fn atomicClear(self: *Flags, inv_mask: Flags) Flags {
        const mask = ~@as(u8, @bitCast(inv_mask));
        const old = @atomicRmw(u8, @as(*u8, @ptrCast(self)), .And, mask, .release);
        return @bitCast(old);
    }
};

pub const Signal = enum(u8) {
    pub const Set = std.bit_set.IntegerBitSet(Signal.num);

    pub const Handler = struct {
        func_ptr:   usize = 0,
        resume_ptr: usize = 0,

        pub fn process(self: *const Handler, signal: Signal, abi: sys.call.Abi, ctx: lib.AnyData) void {
            if (!self.isNull()) {
                sys.call.handleSignal(signal, self, abi, ctx);
            } else {
                defaultAction(signal);
            }
        }

        pub fn defaultAction(signal: Signal) void {
            const task = sched.getCurrentTask();
            const proc = task.spec.user.process;

            switch (signal) {
                .Child,
                .Urgent,
                .WindowResize => {}, // Ignore
                .Continue => { // Continue
                    // TODO: Implement
                    log.warn("TODO: implement SIGCONT handling", .{});
                },
                .Stop,
                .TerminalInput,
                .TerminalOutput,
                .TerminalStop => { // Stop
                    //defer sched.pause();
                    // FIXME: Pause the process

                    proc.list_lock.readLock();
                    defer proc.list_lock.readUnlock();

                    var node = proc.tasks.first;
                    while (node) |n| : (node = n.next) {
                        const user_spec = sched.Task.Specific.User.fromNode(n);
                        if (user_spec == &task.spec.user) {
                            @branchHint(.unlikely);
                            continue;
                        }

                        user_spec.sendSignal(signal);
                    }
                },
                else => { // Terminate
                    proc.stats.fault_signal = signal;
                    proc.terminate(0);
                },
            }
        }

        inline fn isNull(self: *const Handler) bool {
            return self.func_ptr == 0;
        }
    };

    pub const num = 32;
    pub const non_maskable_signals: Set = .{ .mask = @intFromEnum(Signal.Kill) & @intFromEnum(Signal.Stop) };

    None            = 0,
    Abort           = linux.SIG.ABRT,
    Alarm           = linux.SIG.ALRM,
    BadSyscall      = linux.SIG.SYS,
    BrokenPipe      = linux.SIG.PIPE,
    BusError        = linux.SIG.BUS,
    Child           = linux.SIG.CHLD,
    Continue        = linux.SIG.CONT,
    CpuTimeout      = linux.SIG.XCPU,
    EmulatorTrap    = if (@hasDecl(linux.SIG, "EMT")) linux.SIG.EMT else 33,
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

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

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

    const Owner = extern union {
        process: *Self,
        stats: ?*Stats,
    };

    const RbNode = lib.rb.Node;

    var base: std.atomic.Value(u32) = .init(1);
    var rb_tree: lib.rb.Tree(compare, keyCompare) = .{};
    var rb_lock: lib.sync.RwSemaphore = .{};

    value: u32,
    users: lib.atomic.RefCount(u32) = .{},

    rb_node: RbNode = .{},

    owner: Owner = .{ .stats = null },

    lock: lib.sync.Spinlock = .{},
    zombie: bool = false,

    c_node: List.Node = .{}, // process's child list node
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

        if (self.isZombie()) self.owner.stats.?.delete();
        vm.auto.free(Id, self);
    }

    pub inline fn ref(self: *Id) void {
        self.users.inc();
    }

    pub fn deref(self: *Id) void {
        if (!self.users.put()) return;

        log.debug("delete id: {}", .{self.value});
        std.debug.assert(
            (self.isZombie() or self.owner.stats == null) and
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
        std.debug.assert(process.group != group and process.id.lock.isLocked());

        group.lock.lockAtomic();
        defer group.lock.unlockAtomic();

        group.addProcessToGroupAtomic(process);
    }

    pub fn addProcessToGroupAtomic(group: *Id, process: *sys.Process) void {
        std.debug.assert(process.id.lock.isLocked() and group.lock.isLocked());

        if (process.flags.terminate) {
            @branchHint(.cold);
            return;
        }

        std.debug.assert(process.id.p_node.next == null);
        process.group = group;
        group.p_node.insertAfter(&process.id.p_node);
        group.users.inc();
    }

    pub fn processExitFromGroupAtomic(proc: *sys.Process) void {
        const pid = proc.id;
        std.debug.assert(pid.lock.isLocked());

        if (pid != proc.group) {
            proc.group.notifyEvent(proc);
            proc.group.removeProcessFromGroup(proc);
        } else if (proc.group.isSessionOwner()) {
            proc.group.notifyEventAtomic(proc);
            proc.group.session.leaderExit();
        } else if (pid.p_node.next == null) {
            // This process is the group owner and there is no other process in group.
            const session = pid.session.getRemoteSession();
            session.removeGroup(proc.group);
        }
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
        if (!group.isZombie()) group.owner.process.sendSignalAtomic(signal);

        var node = group.p_node.next;
        while (node) |n| : (node = n.next) {
            const id = fromPNode(n);

            id.lock.lockAtomic();
            defer id.lock.unlockAtomic();

            if (!id.isZombie()) id.owner.process.sendSignalAtomic(signal);
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
        return self.zombie;
    }

    pub fn waitForEvent(self: *Id) error{Interrupted}!*Id {
        var waiter: Waiter = .init();
        {
            self.lock.lock();
            defer self.lock.unlock();
            self.wait_queue.push(&waiter.entry);
        }

        errdefer {
            self.lock.lock();
            defer self.lock.unlock();

            _ = self.wait_queue.removeTask(&waiter.entry);
        }

        try sched.getCurrent().doWait(true);
        return waiter.notifier.?;
    }

    pub fn waitForEventAtomic(self: *Id) error{Interrupted}!*Id {
        var waiter: Waiter = .init();
        self.wait_queue.push(&waiter.entry);

        errdefer {
            self.lock.lock();
            defer self.lock.unlock();

            self.wait_queue.removeWeak(&waiter.entry);
        }

        self.lock.unlock();
        try sched.getCurrent().doWait(true);

        return waiter.notifier.?;
    }

    pub inline fn notifyEvent(self: *Id, notifier: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.notifyEventAtomic(notifier);
    }

    pub fn notifyEventAtomic(self: *Id, notifier: *Self) void {
        var node = self.wait_queue.list.first.raw;
        while (node) |n| : (node = n.next) {
            const waiter = Id.Waiter.fromNode(n);

            waiter.notifier = notifier.id;
            notifier.id.ref();
        }

        sched.awakeAll(&self.wait_queue);
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
        if (!group.isZombie()) return group.owner.process;

        const node = group.p_node.findLast();
        const leader = fromPNode(node);

        return if (leader.isZombie()) null else leader.owner.process;
    }

    fn processAttach(self: *Id, process: *Self) void {
        std.debug.assert(process.id == self and self.users.count() == 0 and self.owner.stats == null);

        self.owner = .{ .process = process };
        self.session.setup();
        self.ref();
    }

    fn processExit(self: *Id) void {
        self.lock.lock();
        defer self.lock.unlock();

        const proc = self.owner.process;
        self.owner = .{ .stats = proc.stats };
        self.zombie = true;

        processExitFromGroupAtomic(proc);
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

    inline fn fromCNode(c_node: *Node) *Id {
        return @fieldParentPtr("c_node", c_node);
    }

    inline fn fromPNode(p_node: *SNode) *Id {
        return @fieldParentPtr("p_node", p_node);
    }

    pub inline fn fromGNode(g_node: *SNode) *Id {
        return @fieldParentPtr("g_node", g_node);
    }
};

pub const Stats = struct {
    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    sys_time_ns: u64 = 0,
    user_time_ns: u64 = 0,
    exit_status: u8 = 0,
    fault_signal: Signal = .None,

    inline fn new() ?*Stats {
        const stats = vm.auto.alloc(Stats) orelse return null;
        stats.* = .{};

        return stats;
    }

    inline fn delete(self: *Stats) void {
        vm.auto.free(Stats, self);
    }
};

const Control = struct {
    sig_pending: Signal.Set = .initEmpty(),
    sig_mask: Signal.Set = .initFull(),
    sig_handlers: [Signal.num]Signal.Handler = .{ Signal.Handler{} } ** Signal.num,

    lock: lib.sync.Spinlock = .{},
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

var init_proc: ?*Self = null;

id: *Id,
group: *Id,
stats: *Stats,

/// User id.
uid: u16 = 0,
/// Group id.
gid: u16 = 0,
umask: u16 = 0o022,

abi: sys.call.Abi = .linux_sysv,
flags: Flags = .{},

addr_space: *AddressSpace,

files: FileTable,
root_dir: *vfs.Dentry,
work_dir: *vfs.Dentry,

exe_file: ?*vfs.File = null,
interp_file: ?*vfs.File = null,

parent: *Id,
childs: List = .{},

/// All tasks related to this process.
tasks: TaskList = .{},
/// Lock used to protect `childs` and `tasks`.
list_lock: lib.sync.RwLock = .{},

ctrl: Control = .{},

pub fn init(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) !Self {
    var files: FileTable = try .init(limits.default_max_open_files);
    errdefer files.deinit();

    const stack_pages: u16 = @truncate((stack_size + vm.page_size - 1) / vm.page_size);
    const addr_space = try AddressSpace.create(stack_pages);
    errdefer addr_space.delete();

    const id = Id.new() orelse return error.NoMemory;
    errdefer id.delete();
    const stats = Stats.new() orelse return error.NoMemory;

    root_dir.ref();
    work_dir.ref();
    addr_space.ref();

    return .{
        .id = id,
        .group = id,
        .stats = stats,
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
    errdefer self.deinit();

    self.parent = self.id;
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
    const stats = Stats.new() orelse return error.NoMemory;
    errdefer stats.delete();
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
        .stats = stats,
        .uid = self.uid,
        .gid = self.gid,
        .umask = self.umask,
        .root_dir = self.root_dir,
        .work_dir = self.work_dir,
        .parent = self.id,
        .exe_file = self.exe_file,
        .interp_file = self.interp_file,
        .addr_space = addr_space,
        .files = file_table,
    };

    const group = self.getGroup();
    defer group.deref();

    id.processAttach(new);

    new.id.lock.lockAtomic();
    defer new.id.lock.unlockAtomic();

    group.addProcessToGroup(new);
    self.addChild(new);

    return new;
}

pub fn clear(self: *Self) *sched.Task {
    std.debug.assert(self.childs.first == null);

    const node = self.tasks.first.?;
    const main_task = sched.Task.Specific.User.fromNode(node).toTask();

    var next = node.next;
    while (next) |n| : (next = n.next) {
        const task = sched.Task.Specific.User.fromNode(n).toTask();
        task.delete();
    }

    self.tasks = .{};
    self.addr_space.clear();
    self.files.closeOnExecute();

    self.detachInterpreter();
    self.detachExecutable();
    self.flags = .{};

    return main_task;
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.childs.first == null and self.id == self.group);

    var node = self.tasks.first;
    while (node) |n| {
        node = n.next;

        const task = sched.Task.Specific.User.fromNode(n).toTask();
        task.delete();
    }

    if (self.parent != self.id) self.parent.deref();

    self.id.deref();
    self.tasks.first = null;
    self.root_dir.deref();
    self.work_dir.deref();
    self.files.deinit();

    if (self.exe_file != null) self.detachExecutable();
    if (self.interp_file != null) self.detachInterpreter();
    self.addr_space.deref();
}

pub fn delete(self: *Self) void {
    self.deinit();
    vm.auto.free(Self, self);
}

pub inline fn findById(id: u32) ?*Self {
    const pid = Id.lookup(id) orelse return null;
    defer pid.deref();

    return if (!pid.isZombie()) pid.owner.process else null;
}

pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.exe_file) |exe| {
        try writer.print("{f}:{}", .{exe.dentry.path(), self.id.value});
    } else {
        try writer.print("null:{}", .{self.id.value});
    }
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

/// Add newly created process as child.
/// *Child id lock is not held be careful when using.*
pub fn addChild(self: *Self, child: *Self) void {
    std.debug.assert(self != child);

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    child.id.ref();
    self.id.ref();

    child.parent = self.id;
    self.childs.append(&child.id.c_node);
}

pub fn detachAllChilds(self: *Self) void {
    // No internal locks are needed, as this is
    // called from the `terminate`.
    lib.debug.assert(
        self.flags.terminate and self.tasks.first == null, @src()
    );

    if (self == init_proc) init_proc = null;
    defer self.childs.first = null;

    var node = self.childs.first;
    while (node) |n| : (node = n.next) {
        const id = Id.fromCNode(n);

        id.lock.lock();
        defer id.deref();
        defer id.lock.unlock();

        const child = if (!id.isZombie()) id.owner.process else continue;

        child.ctrl.lock.lockAtomic();
        defer child.ctrl.lock.unlockAtomic();

        self.id.deref();

        if (init_proc) |p| {
            p.addChild(child);
        } else {
            @branchHint(.cold);
            init_proc = child;
            child.parent = child.id;
        }
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

pub fn detachTask(self: *Self, task: *sched.Task) bool {
    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    const node = &task.spec.user.node;
    if (node.next == node) {
        // Thread was already terminated.
        @branchHint(.cold);
        return false;
    }

    self.tasks.remove(node);
    // Set next pointer to self to mark thread as terminated.
    node.next = node;

    return true;
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

pub fn terminateThread(self: *Self, task: *sched.Task, status: u8) bool {
    const proc_exit = blk: {
        self.ctrl.lock.lock();
        defer self.ctrl.lock.unlock();

        if (self.flags.terminate) return false;
        if (!self.detachTask(task)) return true;

        if (self.tasks.first == null) {
            self.flags.terminate = true;
            break :blk true;
        }

        break :blk false;
    };

    sys.call.stopThread(self.abi, task);

    if (proc_exit) self.terminateComplete(status);
    if (task == sched.getCurrent().current_task) sched.terminate();

    return true;
}

/// Terminate process: kill all threads, detach childs to init, set exit status.
pub fn terminate(self: *Self, status: u8) noreturn {
    std.debug.assert(getCurrent() == self);

    const task = sched.getCurrentTask();

    {
        self.ctrl.lock.lock();
        defer self.ctrl.lock.unlock();

        if (self.flags.terminate or self.tasks.len() > 1) @panic("remote/multi-thread termination is not implemented");
        self.flags.terminate = true;
    }

    if (!self.detachTask(task)) @panic("remote/multi-thread termination is not implemented");

    sys.call.stopThread(self.abi, task);
    self.terminateComplete(status);

    sched.terminate();
}

/// Returns `false` if `id` is not a child of the process
/// or was waited by other thread.
pub fn waitChildExit(self: *Self, id: *Id) error{Interrupted}!bool {
    // FIXME: Check if id is a child of this process.
    {
        self.id.lock.lock();
        defer self.id.lock.unlock();

        while (!id.isZombie()) {
            defer self.id.lock.lock();

            const waited_id = try self.id.waitForEventAtomic();
            waited_id.deref();
        }
    }

    self.list_lock.writeLock();
    defer self.list_lock.writeUnlock();

    // Check if child is not removed from the list.
    if (id.c_node.next != &id.c_node) {
        self.childs.remove(&id.c_node);
        // Id should be refereced from the caller, so it's safe
        // and needed to dereference it here.
        lib.debug.assert(id.users.value.raw > 1, @src());
        id.users.dec();
    }

    return true;
}

pub fn waitAnyChildExit(self: *Self, nowait: bool) error{Interrupted}!?*Id {
    self.id.lock.lock();

    while (true) {
        {
            self.list_lock.writeLock();
            defer self.list_lock.writeUnlock();

            if (self.childs.first == null) {
                self.id.lock.unlock();
                return null;
            }

            var node = self.childs.first;
            while (node) |n| : (node = n.next) {
                const id = Id.fromCNode(n);
                if (id.isZombie()) {
                    self.id.lock.unlock();
                    self.childs.remove(&id.c_node);
                    // Set next pointer to self to tell
                    // that child was remove from the list.
                    id.c_node.next = &id.c_node;

                    return id;
                }
            }
        }

        if (nowait) {
            @branchHint(.unlikely);
            self.id.lock.unlock();
            return null;
        }

        const id = try self.id.waitForEventAtomic();
        id.deref();

        self.id.lock.lock();
    }
}

pub fn sendSignal(self: *Self, signal: Signal) void {
    const sig = @intFromEnum(signal);

    self.ctrl.lock.lock();
    defer self.ctrl.lock.unlock();

    if (!self.ctrl.sig_mask.isSet(sig)) {
        self.ctrl.sig_pending.set(@intFromEnum(signal));
        return;
    }

    {
        self.list_lock.readLock();
        defer self.list_lock.readUnlock();

        var node = self.tasks.first;
        while (node) |n| : (node = n.next) {
            const user = sched.Task.Specific.User.fromNode(n);
            if (!user.sig_mask.isSet(@intFromEnum(signal))) continue;

            user.sendSignal(signal);
            return;
        }
    }

    self.ctrl.sig_pending.set(@intFromEnum(signal));
}

pub fn sendSignalAtomic(self: *Self, signal: Signal) void {
    // TODO: implement signals!
    log.warn("unhandled signal: {s} -> {f}", .{@tagName(signal), self});
    self.sendSignal(signal);
}

pub fn deliverPendingSignals(self: *Self) void {
    self.ctrl.lock.lock();
    defer self.ctrl.lock.unlock();

    self.deliverPendingSignalsAtomic();
}

pub fn deliverPendingSignalsAtomic(self: *Self) void {
    var signals = self.ctrl.sig_pending.intersectWith(self.ctrl.sig_mask);
    if (signals.mask == 0) return;

    self.list_lock.readLock();
    defer self.list_lock.readUnlock();

    var node = self.tasks.first;
    while (node) |n| : (node = n.next) {
        const user = sched.Task.Specific.User.fromNode(n);
        const to_send = signals.intersectWith(user.sig_mask);
        if (to_send.mask == 0) continue;

        user.sendSignals(to_send);

        self.ctrl.sig_pending.toggleSet(to_send);
        signals.toggleSet(self.ctrl.sig_mask);

        if (signals.mask == 0) break;
    }
}

fn terminateComplete(self: *Self, status: u8) void {
    lib.debug.assert(self.tasks.first == null, @src());
    self.stats.exit_status = status;

    self.detachAllChilds();

    // Process exit notifies the group if we are not in the same group
    const group = self.group;
    self.id.processExit();

    // Parent is also might be our group owner
    if (self.parent != self.id and self.parent != group) self.parent.notifyEvent(self);

    self.delete();
}
