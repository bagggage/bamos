//! # Registers compile time abstraction

const std = @import("std");

const log = @import("../log.zig");
const io = @import("io.zig");

pub const Register = struct {
    pub const Access = enum {
        read,
        write,
        rw
    };

    name: [:0]const u8,
    offset: comptime_int,
    Type: ?type = null,
    access: Access = .rw,

    pub inline fn init(
        comptime name: [:0]const u8,
        comptime offset: comptime_int,
        comptime Type: ?type, 
        comptime access: Access,
    ) Register {
        comptime {
            if (Type) |T| {
                const info = @typeInfo(T);

                if (info != .Int and info != .Struct)
                    @compileError("Register type can only be an integer or a structure, found: "++@typeName(Type.?));
            }
        }

        return .{ .name = name, .offset = offset, .Type = Type, .access = access };
    }

    pub inline fn getSize(self: Register) ?comptime_int {
        return if (self.Type) |T| @sizeOf(T) else null;
    }
};

pub fn Group(
    comptime IoMechanism: type,
    comptime base: ?comptime_int,
    comptime size: ?comptime_int,
    comptime regs: []const Register
) type {
    if (base) |val| {
        std.debug.assert(val % @sizeOf(IoMechanism.Address) == 0);
    }

    comptime var fields: []const std.builtin.Type.EnumField = &.{};

    inline for (regs[0..], 0..) |r, i| {
        fields = fields ++ [_]std.builtin.Type.EnumField{.{
            .name = r.name,
            .value = i
        }};
    }

    const reg_names = std.builtin.Type{
        .Enum = .{
            .fields = fields,
            .decls = &.{},
            .tag_type = u8,
            .is_exhaustive = false
        }
    };
    const NamesType: type = @Type(reg_names);

    return struct {
        pub const AddressType: type = IoMechanism.Address;
        pub const DataType: type = IoMechanism.Data;

        pub const Names = NamesType;

        pub const byte_size: comptime_int = if (size) |val| val else calcSize();

        const Self = @This();
        const BaseType = if (base != null) void else AddressType; 

        dyn_base: BaseType = undefined,

        comptime members: []const Register = regs,

        fn getRegInfo(comptime member: Names) Register {
            return regs[@intFromEnum(member)];
        }

        fn calcSize() comptime_int {
            comptime var max_offset = 0;

            for (regs) |r| {
                if (r.offset > max_offset) max_offset = r.offset;
            }

            return max_offset + @sizeOf(DataType);
        }

        inline fn getBase(self: Self) AddressType {
            return if (base) |val| val else self.dyn_base;
        }

        fn RegIntType(comptime member: Names) type {
            const Type = getRegInfo(member).Type orelse return DataType;
            const info = @typeInfo(Type);

            if (info == .Int) return Type;

            return std.meta.Int(.unsigned, @bitSizeOf(Type));
        }

        fn ReferenceGroupEx(comptime offset: AddressType, comptime T: type) type {
            const new_base = if (base) |val| (val + offset) else null;
            return Group(IoMechanism, new_base, null, from(T));
        }

        fn ReferenceGroup(comptime member: Names, comptime T: type) type {
            return ReferenceGroupEx(getRegInfo(member).offset, T);
        }

        pub fn Ref(comptime T: type) type { return ReferenceGroupEx(0, T); }

        pub fn init() !Self {
            if (IoMechanism.init) |initFn| {
                _ = try initFn(base.?, byte_size);
            }

            return .{};
        }

        pub fn initBase(base_addr: AddressType) !Self {
            if (IoMechanism.init) |initFn| {
                return .{ .dyn_base = try initFn(base_addr, byte_size) };
            }

            return .{ .dyn_base = base_addr };
        }

        pub inline fn read(self: Self, comptime member: Names) RegIntType(member) {
            @setRuntimeSafety(false);

            const r = comptime getRegInfo(member);
            const r_size = comptime r.getSize() orelse @sizeOf(DataType);

            comptime {
                if (r.access == .write) @compileError("Register '" ++ r.name ++ "' is write-only.");
            }

            if (comptime (r.offset % @sizeOf(DataType)) != 0 or r_size != @sizeOf(DataType)) {
                return IoMechanism.readNonUniform(
                    RegIntType(member),
                    self.getBase(),
                    comptime r.offset * std.mem.byte_size_in_bits,
                );
            }
            else {
                return @truncate(IoMechanism.read(self.getBase() +% r.offset));
            }
        }

        pub inline fn write(self: Self, comptime member: Names, data: RegIntType(member)) void {
            @setRuntimeSafety(false);

            const r = comptime getRegInfo(member);
            const r_size = comptime r.getSize() orelse @sizeOf(DataType);

            comptime {
                if (r.access == .read) @compileError("Register '" ++ r.name ++ "' is read-only.");
            }

            if (comptime (r.offset % @sizeOf(DataType)) != 0 or r_size != @sizeOf(DataType)) {
                IoMechanism.writeNonUniform(
                    self.getBase(),
                    comptime r.offset * std.mem.byte_size_in_bits,
                    data
                );
            }
            else {
                IoMechanism.write(self.getBase() +% r.offset, data);
            }
        }

        pub inline fn get(self: Self, comptime T: type, comptime member: Names) T {
            return @bitCast(self.read(member));
        }

        pub inline fn set(self: Self, comptime member: Names, data: anytype) void {
            self.write(member, @bitCast(data));
        }

        pub inline fn referenceAs(self: Self, comptime T: type, comptime member: Names) ReferenceGroup(member, T) {
            return self.referenceAsOffset(T, getRegInfo(member).offset);
        }

        pub inline fn referenceAsOffset(self: Self, comptime T: type, offset: AddressType) ReferenceGroupEx(0, T) {
            if (comptime base != null) {
                return .{};
            } else {
                return .{ .dyn_base = self.dyn_base + offset };
            }
        }
    };
}

/// Read-only modifier for register field in struct layout.
/// 
/// For `extern`/`packed` structs use postfixies: `E`/`P`.
pub fn ReadOnly(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return struct {
        pub const access = Register.Access.read;
        value: IntType
    };
}

/// Write-only modifier for register field in struct layout.
/// 
/// For `extern`/`packed` structs use postfixies: `E`/`P`.
pub fn WriteOnly(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return struct {
        pub const access = Register.Access.write;
        value: IntType
    };
}

/// Read-only modifier for register field in **`extern`** struct layout.
pub fn ReadOnlyE(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return extern struct {
        pub const access = Register.Access.read;
        value: IntType
    };
}

/// Write-only modifier for register field in **`extern`** struct layout.
pub fn WriteOnlyE(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return extern struct {
        pub const access = Register.Access.write;
        value: IntType
    };
}

/// Read-only modifier for register field in **`packed`** struct layout.
pub fn ReadOnlyP(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return packed struct {
        pub const access = Register.Access.read;
        value: IntType
    };
}

/// Write-only modifier for register field in **`packed`** struct layout.
pub fn WriteOnlyP(comptime IntType: type) type {
    comptime { std.debug.assert(std.meta.Int(.unsigned, @bitSizeOf(IntType)) == IntType); }
    return packed struct {
        pub const access = Register.Access.write;
        value: IntType
    };
}

pub const reg = Register.init;

pub fn from(comptime Layout: type) []const Register {
    comptime var result: []const Register = &.{};
    const layout_info = @typeInfo(Layout);

    switch (layout_info) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                if (field.name[0] == '_') continue;

                result = result ++ .{
                    Register.init(
                        field.name,
                        @offsetOf(Layout, field.name),
                        field.type,
                        getTypeAccess(field.type)
                    )
                };
            }
        },
        .Union => |info| {
            inline for (info.fields) |field| {
                result = result ++ from(field.type);
            }
        },
        else => @compileError("Layout must be a struct or union, found '" ++ @typeName(Layout) ++ "'")
    }

    return result;
}

fn getTypeAccess(comptime Type: type) Register.Access {
    if (@typeInfo(Type) != .Struct) return .rw;
    if (@hasDecl(Type, "access") == false) return .rw;
    if (@TypeOf(Type.access) != Register.Access) return .rw;

    return Type.access;
}
