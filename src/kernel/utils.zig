//! # Utilities

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");

pub const algorithm = @import("utils/algorithm.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86-64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const AnyData = struct {
    ptr: ?*anyopaque = null,

    pub inline fn from(ptr: ?*anyopaque) AnyData {
        return .{ .ptr = ptr };
    }

    pub inline fn set(self: *AnyData, ptr: ?*anyopaque) void {
        self.ptr = ptr;
    }

    pub inline fn as(self: AnyData, comptime T: type) ?*T {
        return if (self.ptr) |val| @as(*T, @ptrCast(@alignCast(val))) else null;
    }
};

pub const Bitmap = @import("utils/Bitmap.zig");
pub const BinaryTree = @import("utils/binary-tree.zig").BinaryTree;

pub const CmpResult = enum {
    less,
    equals,
    great
};

pub fn CmpFnType(comptime T: type) type {
    return fn(*const T, *const T) CmpResult;
}

pub const List = std.DoublyLinkedList;
pub const SList = std.SinglyLinkedList;
pub const Spinlock = @import("utils/Spinlock.zig");
pub const Heap = @import("utils/Heap.zig");

pub const byte_size = 8;
pub const kb_size = 1024;
pub const mb_size = kb_size * 1024;
pub const gb_size = mb_size * 1024;

pub inline fn calcAlign(comptime T: type, value: T, alignment: T) T {
    return ((value + (alignment - 1)) & ~(alignment - 1));
}

pub inline fn errToInt(err: anyerror) i16 {
    @setRuntimeSafety(false);
    return std.math.negateCast(@intFromError(err)) catch unreachable;
}

pub inline fn intToErr(comptime Err: type, int: i16) Err {
    const uint: u16 = @intCast(-int);
    return @as(Err, @errorCast(@errorFromInt(uint)));
}

pub inline fn halt() noreturn {
    while (true) arch.halt();
}

/// @export
pub fn profile(src: ?std.builtin.SourceLocation, func: anytype, args: anytype) void {
    const begin = profileBegin();

    const is_ret_error = comptime blk: {
        const fn_type = @typeInfo(@TypeOf(func)).Fn;

        if (fn_type.return_type) |ret_t| {
            const ret_info = @typeInfo(ret_t);

            break :blk (ret_info == .ErrorSet or ret_info == .ErrorUnion);
        }

        break :blk false;
    };

    if (is_ret_error) {
        _ = @call(.auto, func, args) catch |err| {
            log.err("Error while profiling: {s}", .{@errorName(err)});
            return;
        };
    } else {
        _ = @call(.auto, func, args);
    }

    const cycles = profileEnd(begin);
    const cpu_mhz = arch.getCpuInfo().base_frequency;
    const ms = if(cpu_mhz != 0) cycles / (cpu_mhz * 1000) else 0;

    if (src) |s| {
        log.warn("Profile at {s}.{s}:{}:{} - {}t ~ {}ms", .{
            s.file, s.fn_name, s.line, s.column, cycles, ms
        });
    } else {
        log.warn("Profile: {s} - {}t ~ {}ms", .{
            @typeName(@TypeOf(func)), cycles, ms
        });
    }
}

pub inline fn profileBegin() usize {
    return arch.timestamp();
}

pub inline fn profileEnd(begin: usize) usize {
    return arch.timestamp() - begin;
}

const TypeHasher = std.hash.Fnv1a_32;

fn typeIdShort(comptime T: type) u32 {
    @setEvalBranchQuota(10000);

    comptime var hasher = TypeHasher.init();
    const info = @typeInfo(T);

    hasher.update(&.{@intFromEnum(info)});

    switch (info) {
        .ComptimeInt, .ComptimeFloat, .Int, .Float,
        .Undefined, .NoReturn, .Null,
        .Type, .EnumLiteral,
        .Vector, .Void,
        .Bool => hasher.update(@typeName(T)),
        .Array => |a| {
            const type_id = typeIdShort(a.child);
            hasher.update(std.mem.asBytes(&type_id));
            hasher.update(std.mem.asBytes(a.len));
        },
        .Optional => |o| {
            const type_id = typeIdShort(o.child);
            hasher.update(std.mem.asBytes(&type_id));
        },
        .Pointer => |p| {
            const type_id = typeIdShort(p.child);
            hasher.update(std.mem.asBytes(&type_id));
            hasher.update(&.{
                p.alignment, @intFromEnum(p.size),
                @intFromBool(p.is_allowzero),@intFromBool(p.is_const),
                @intFromBool(p.is_volatile),@intFromEnum(p.address_space),
            });
        },
        .Union,
        .Struct => {
            const s = switch (info) { .Struct => |s| s, .Union => |u| u, else => unreachable };

            for (s.decls) |decl| hasher.update(decl.name);
            for (s.fields) |field| {
                hasher.update(field.name);

                const size = @sizeOf(field.type);
                hasher.update(&.{@intFromEnum(@typeInfo(field.type))});
                hasher.update(std.mem.asBytes(&size));
            }
        },
        .Opaque => |op| {
            for (op.decls) |decl| hasher.update(decl.name);
        },
        .Enum => |e| {
            for (e.decls) |decl| hasher.update(decl.name);
            for (e.fields) |field| {
                hasher.update(field.name);
                const value: usize = field.value;
                hasher.update(std.mem.asBytes(&value));
            }
        },
        .ErrorSet => |e| {
            if (e) |set| for (set) |err| { hasher.update(err.name); };
        },
        .ErrorUnion => |eu| {
            var type_id = typeIdShort(eu.error_set);
            hasher.update(std.mem.asBytes(&type_id));

            type_id = typeIdShort(eu.payload);
            hasher.update(std.mem.asBytes(&type_id));
        },
        .Fn => |f| {
            for (f.params) |param| hasher.update(&.{@intFromEnum(@typeInfo(param.type orelse void))});
            if (f.return_type) |RetT| hasher.update(&.{@intFromEnum(@typeInfo(RetT))});
        },
        else => {
            const size = @sizeOf(T); const algn = @alignOf(T);
            hasher.update(std.mem.asBytes(&size));
            hasher.update(std.mem.asBytes(&algn));
        }
    }

    return hasher.final();
}

fn _typeId(comptime T: type) u32 {
    return comptime opaque {
        pub fn typeIdImpl(comptime Type: type, comptime level: comptime_int) u32 {
            if (level > 2) return typeIdShort(Type);

            const next_lvl = level + 1;

            comptime var hasher = TypeHasher.init();
            const info = @typeInfo(Type);

            hasher.update(&.{@intFromEnum(info)});

            comptime switch (info) {
                .ComptimeInt, .ComptimeFloat, .Int, .Float,
                .Undefined, .NoReturn, .Null,
                .Type, .EnumLiteral,
                .Vector, .Void,
                .Bool => hasher.update(@typeName(Type)),
                .Struct => |s| {
                    if (s.backing_integer) |IntT| hasher.update(@typeName(IntT));
                    for (s.decls) |decl| hasher.update(decl.name);
                    for (s.fields) |field| {
                        hasher.update(field.name);

                        const type_id = typeIdImpl(field.type, next_lvl);
                        hasher.update(std.mem.asBytes(&type_id));
                    }

                    hasher.update(&.{ @intFromBool(s.is_tuple), @intFromEnum(s.layout) });
                },
                .Array => |a| {
                    const type_id = typeIdImpl(a.child, next_lvl);
                    hasher.update(std.mem.asBytes(&type_id));
                    hasher.update(std.mem.asBytes(a.len));
                },
                .Fn => |f| {
                    for (f.params) |param| {
                        if (param.type) |ArgT| {
                            const type_id = typeIdImpl(ArgT, 0);
                            hasher.update(std.mem.asBytes(&type_id));
                        }
                    }
                    if (f.return_type) |RetT| {
                        const type_id = typeIdImpl(RetT, 0);
                        hasher.update(std.mem.asBytes(&type_id));
                    }
                },
                .Enum => |e| {
                    for (e.decls) |decl| hasher.update(decl.name);
                    for (e.fields) |field| {
                        hasher.update(field.name);
                        const value: usize = field.value;
                        hasher.update(std.mem.asBytes(&value));
                    }

                    hasher.update(@typeName(e.tag_type));
                },
                .ErrorSet => |e| {
                    if (e) |set| for (set) |err| {
                        hasher.update(err.name);
                    };
                },
                .ErrorUnion => |eu| {
                    var type_id = typeIdImpl(eu.error_set, next_lvl);
                    hasher.update(std.mem.asBytes(&type_id));

                    type_id = typeIdImpl(eu.payload, next_lvl);
                    hasher.update(std.mem.asBytes(&type_id));
                },
                .Union => |u| {
                    var type_id = 0;
                    if (u.tag_type) |TagT| {
                        type_id = typeIdImpl(TagT, next_lvl);
                        hasher.update(std.mem.asBytes(&type_id));
                    }

                    for (u.decls) |decl| hasher.update(decl.name);
                    for (u.fields) |field| {
                        hasher.update(field.name);

                        type_id = typeIdImpl(field.type, next_lvl);
                        hasher.update(std.mem.asBytes(&type_id));
                    }

                    hasher.update(&.{@intFromEnum(u.layout)});
                },
                .Optional => |o| {
                    const type_id = typeIdImpl(o.child, next_lvl);
                    hasher.update(std.mem.asBytes(&type_id));
                },
                .Opaque => |o| {
                    for (o.decls) |decl| hasher.update(decl.name);
                },
                .Pointer => |p| {
                    const type_id = typeIdImpl(p.child, next_lvl);
                    hasher.update(std.mem.asBytes(&type_id));
                    hasher.update(&.{
                        p.alignment, @intFromEnum(p.size),
                        @intFromBool(p.is_allowzero),@intFromBool(p.is_const),
                        @intFromBool(p.is_volatile),@intFromEnum(p.address_space),
                    });
                },
                .Frame,
                .AnyFrame => @compileError("Type ID not supported for Frames")
            };

            return comptime hasher.final();
        }
    }.typeIdImpl(T, 0);
}

pub fn typeId(comptime T: type) u32 {
    const name = comptime @typeName(T);

    comptime var hasher = TypeHasher.init();
    hasher.update(name);

    return hasher.final();
}
