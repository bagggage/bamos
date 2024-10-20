const std = @import("std");
const builtin = @import("builtin");

pub const algorithm = @import("utils/algorithm.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86-64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const AnyData = struct {
    ptr: ?*anyopaque = null,

    pub inline fn set(self: *AnyData, ptr: ?*anyopaque) void {
        self.ptr = ptr;
    }

    pub inline fn as(self: *const AnyData, comptime T: type) ?*T {
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

pub inline fn halt() noreturn {
    while (true) arch.halt();
}

const TypeHasher = std.hash.Fnv1a_32;

fn typeIdShort(comptime T: type) u32 {
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

pub fn typeId(comptime T: type) u32 {
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
                        type_id = typeIdImpl(TagT);
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