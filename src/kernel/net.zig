//! # Network subsystem

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("lib.zig");
const log = std.log.scoped(.net);
const linux = std.os.linux;
const vfs = @import("vfs.zig");
const vm = @import("vm.zig");

pub const Error = vfs.Error || error {
    AddressInUse,
    Already,
    Connected,
    ConnectionRefused,
    InProgress,
    NotConnected,
    NotSocket,
    ProtocolTypeMissmatch,
    Timeout,
    UnsupportedFamily,
    UnsupportedProtocol,
    UnsupportedSocketType,
};

pub const Socket = @import("net/Socket.zig");
pub const unix = @import("net/unix.zig");

pub const Family = enum(u8) {
    pub const Descriptor = struct {
        pub const CreateSocketFn = *const fn (Socket.Type) Error!*Socket;

        name: []const u8,
        create_socket: CreateSocketFn,
    };

    pub const max = 256;

    none = linux.AF.UNSPEC,
    unix = linux.AF.UNIX,
    inet = linux.AF.INET,
    _
};

pub const Packet = struct {
    pub const max_size = vm.PageAllocator.max_alloc_pages * vm.page_size;
    pub const max_small_size = vm.page_size / 2;

    pub const List = lib.atomic.SinglyLinkedList;
    pub const Node = List.Node;

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 1024,
    };

    node: Node = .{},
    buffer: [*]u8,
    data: u32 = 0,
    tail: u32 = 0,
    size: u32 = 0,
    ref_counter: lib.atomic.RefCount(u32) = .{},

    pub fn new(size: u32) vm.Error!*Packet {
        if (size > max_size) {
            @branchHint(.cold);
            return error.MaxSize;
        }

        const self = vm.auto.alloc(Packet) orelse return error.NoMemory;
        errdefer vm.auto.free(Packet, self);

        const ptr, const real_size = if (size < max_small_size) blk: {
            const buffer = vm.gpa.allocMany(u8, size) orelse return error.NoMemory;
            break :blk .{ @intFromPtr(buffer.ptr), size };
        } else blk: {
            const rank = vm.bytesToRank(size);
            const real_size = vm.rankToBytes(rank);

            const phys = vm.PageAllocator.alloc(rank) orelse return error.NoMemory;
            break :blk .{ vm.getVirtLma(phys), real_size };
        };

        self.* = .{ .buffer = @ptrCast(ptr), .size = @truncate(real_size) };

        return self;
    }

    pub fn delete(self: *Packet) void {
        if (self.size < max_small_size) {
            vm.gpa.free(self.buffer);
        } else {
            vm.PageAllocator.free(vm.getPhysLma(self.buffer), vm.bytesToRank(self.size));
        }

        vm.auto.delete(Packet, self);
    }

    pub inline fn ref(self: *Packet) void {
        return self.ref_counter.inc();
    }

    pub inline fn deref(self: *Packet) void {
        if (self.ref_counter.put()) self.delete();
    }
};

pub const IoFlags = packed struct(u16) {
    out_of_bound: bool = false,
    peek: bool = false,
    dont_route: bool = false,
    ctrl_trucate: bool = false,
    probe: bool = false,
    truncate: bool = false,
    dont_wait: bool = false,
    end_of_record: bool = false,
    wait_all: bool = false,
    finish: bool = false,
    synchronize: bool = false,
    confirm: bool = false,
    reset: bool = false,
    error_queue: bool = false,
    no_signal: bool = false,
    more_data: bool = false,
};

var families: [Family.max]?*const Family.Descriptor = .{ null } ** Family.max;
var family_rw_lock: lib.sync.RwLock = .{};

pub fn init() !void {
    try unix.init();
}

pub fn registerProtocolFamily(family: Family, desc: *const Family.Descriptor) error{Exists}!void {
    if (family == .none or @intFromEnum(family) >= Family.max) return error.Exists;

    family_rw_lock.writeLock();
    defer family_rw_lock.writeUnlock();

    const idx = @intFromPtr(family) - 1;
    if (families[idx] != null) return error.Exists;

    families[idx] = desc;
}

pub fn unregisterProtocolFamily(family: Family, desc: *const Family.Descriptor) error{NoEnt}!void {
    if (family == .none or @intFromEnum(family) >= Family.max) return error.NoEnt;

    family_rw_lock.writeLock();
    defer family_rw_lock.writeUnlock();

    const idx = @intFromPtr(family) - 1;
    if (families[idx] != desc) return error.NoEnt;

    families[idx] = desc;
}

pub fn createSocket(family: Family, @"type": Socket.Type) Error!*Socket {
    if (family == .none or @intFromEnum(family) >= Family.max) return error.UnsupportedFamily;

    const desc = blk: {
        family_rw_lock.readLock();
        defer family_rw_lock.readUnlock();

        const idx = @intFromPtr(family) - 1;
        break :blk families[idx] orelse return error.UnsupportedFamily;
    };

    return desc.create_socket(@"type");
}
