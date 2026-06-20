//! # Process Structure

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const sched = @import("../sched.zig");
const sys = @import("../sys.zig");
const linux = std.os.linux;
const Teletype = @import("../dev.zig").classes.Teletype;
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
    deinitialized: bool = false,

    unused: u5 = 0,
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

        pub inline fn getId(self: *Session) *Id {
            return @fieldParentPtr("session", self);
        }
    };

    pub const alloc_config: vm.auto.Config = .{ .allocator = .oma };

    value: u32,
    users: lib.atomic.RefCount(u32) = .{},

    rb_node: lib.rb.Node = .{},

    process: ?*Self = null,

    lock: lib.sync.Spinlock = .{},
    status: u8 = 0, // process exit status

    p_node: SList.Node = .{}, // processes list node
    g_node: SList.Node = .{}, // groups list node

    session: Session = .{},
    wait_queue: sched.WaitQueue = .{},

    pub inline fn new() ?*Id {
        return bindings.getInstance().sys.process.id.new();
    }

    pub inline fn delete(self: *Id) void {
        bindings.getInstance().sys.process.id.delete(self);
    }

    pub inline fn ref(self: *Id) void {
        self.users.inc();
    }

    pub inline fn deref(self: *Id) void {
        return bindings.getInstance().sys.process.id.deref(self);
    }

    pub inline fn lookup(id: u32) ?*Id {
        return bindings.getInstance().sys.process.id.lookup(id);
    }

    pub inline fn sendSignalToGroup(group: *Id, signal: Signal) void {
        group.lock.lock();
        defer group.lock.unlock();

        group.sendSignalToGroupAtomic(signal);
    }

    pub inline fn sendSignalToGroupAtomic(group: *Id, signal: Signal) void {
        bindings.getInstance().sys.process.id.sendSignalToGroupAtomic(group, signal);
    }

    pub inline fn isZombie(self: *Id) bool {
        return self.process == null;
    }

    pub inline fn waitForGroupEvent(group: *Id) *Id {
        return bindings.getInstance().sys.process.id.waitForGroupEvent(group);
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

    inline fn fromRbNode(rb_node: *lib.rb.Node) *Id {
        return @fieldParentPtr("rb_node", rb_node);
    }

    inline fn fromPNode(p_node: *SNode) *Id {
        return @fieldParentPtr("p_node", p_node);
    }

    pub inline fn fromGNode(g_node: *SNode) *Id {
        return @fieldParentPtr("g_node", g_node);
    }
};

pub const Control = struct {
    const SignalSet = std.bit_set.IntegerBitSet(Signal.num);

    sig_mask: SignalSet = .initEmpty(),
    sig_handlers: [Signal.num]Signal.Handler = .{ Signal.Handler{} } ** Signal.num,

    lock: lib.sync.Spinlock = .{},
};

pub const alloc_config: vm.auto.Config = .{
    .allocator = .oma,
};

id: *Id,
group: *Id,

/// User id.
uid: u16 = 0,
/// Group id.
gid: u16 = 0,

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

addr_space: *AddressSpace,
ctrl: Control = .{},

/// All tasks related to this process.
tasks: TaskList = .{},
/// Lock used to protect `childs` and `tasks`.
list_lock: lib.sync.RwLock = .{},

pub inline fn init(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) vm.Error!Self {
    return bindings.getInstance().sys.process.init(stack_size, root_dir, work_dir);
}

pub inline fn create(stack_size: usize, root_dir: *vfs.Dentry, work_dir: *vfs.Dentry) vm.Error!*Self {
    return bindings.getInstance().sys.process.create(stack_size, root_dir, work_dir);
}

pub inline fn clone(self: *Self) vfs.Error!*Self {
    return bindings.getInstance().sys.process.clone(self);
}

pub inline fn clear(self: *Self) *sched.Task {
    return bindings.getInstance().sys.process.clear(self);
}

pub inline fn deinit(self: *Self) void {
    return bindings.getInstance().sys.process.deinit(self);
}

pub inline fn delete(self: *Self) void {
    return bindings.getInstance().sys.process.delete(self);
}

pub inline fn findById(id: u32) ?*Self {
    const pid = Id.lookup(id) orelse return null;
    defer pid.deref();

    return pid.process;
}

pub inline fn fromNode(node: *Node) *Self {
    return @fieldParentPtr("node", node);
}

pub inline fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return bindings.getInstance().sys.process.format(self, writer);
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
pub inline fn addChild(self: *Self, child: *Self) void {
    bindings.getInstance().sys.process.addChild(self, child);
}

pub inline fn removeChild(self: *Self, child: *Self) void {
    bindings.getInstance().sys.process.removeChild(self, child);
}

pub inline fn createTask(self: *Self) vm.Error!*sched.Task {
    return bindings.getInstance().sys.process.createTask(self);
}

pub inline fn pushTask(self: *Self, task: *sched.Task) void {
    bindings.getInstance().sys.process.pushTask(self, task);
}

pub inline fn detachTask(self: *Self, task: *sched.Task) void {
    bindings.getInstance().sys.process.detachTask(self, task);
}

pub inline fn attachControlTerminal(self: *Self, tty: *Teletype) vfs.Error!void {
    return bindings.getInstance().sys.process.attachControlTerminal(self, tty);
}

pub inline fn pageFault(self: *Self, address: usize, cause: vm.FaultCause) bool {
    return bindings.getInstance().sys.process.pageFault(self, address, cause);
}

pub inline fn getGroup(self: *Self) *Id {
    self.id.lock.lock();
    defer self.id.lock.unlock();

    const group = self.group;
    group.users.inc();

    return group;
}

pub inline fn spawnSession(self: *Self) void {
    bindings.getInstance().sys.process.spawnSession(self);
}

pub inline fn terminateThreads(self: *Self) ?*sched.Task {
    return bindings.getInstance().sys.process.terminateThreads(self);
}

/// Terminate process: kill all threads, detach childs to init, set exit status.
pub inline fn terminate(self: *Self, status: u8) void {
    bindings.getInstance().sys.process.terminate(self, status);
}

pub inline fn waitChildExit(self: *Self, nowait: bool) ?*Id {
    return bindings.getInstance().sys.process.waitChildExit(self, nowait);
}

pub inline fn waitEvent(self: *Self) void {
    self.id.lock.lock();
    sched.waitUnlock(&self.id.wait_queue, &self.id.lock);
}

pub inline fn notifyEvent(self: *Self) void {
    self.id.lock.lock();
    defer self.id.lock.unlock();

    sched.awakeAll(&self.id.wait_queue);
}

pub inline fn isZombie(self: *Self) bool {
    return self.id.isZombie();
}

pub inline fn sendSignal(self: *Self, signal: Signal) void {
    bindings.getInstance().sys.process.sendSignal(self, signal);
}

pub inline fn sendSignalAtomic(self: *Self, signal: Signal) void {
    bindings.getInstance().sys.process.sendSignalAtomic(self, signal);
}
