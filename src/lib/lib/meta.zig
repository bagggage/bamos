// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const TypeHasher = std.hash.Fnv1a_32;

pub fn typeId(comptime T: type) u32 {
    const name = comptime @typeName(T);

    comptime var hasher = TypeHasher.init();
    hasher.update(name);

    return hasher.final();
}

pub inline fn errToInt(err: anyerror) i16 {
    @setRuntimeSafety(false);
    return std.math.negateCast(@intFromError(err)) catch unreachable;
}

pub inline fn intToErr(comptime Err: type, int: i16) Err {
    const uint: u16 = @intCast(-int);
    return @as(Err, @errorCast(@errorFromInt(uint)));
}

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
