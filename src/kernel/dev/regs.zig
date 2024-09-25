//! # Registers compile time abstraction

const std = @import("std");
const Type = std.builtin.Type;

const io = @import("io.zig");
const vm = @import("../vm.zig");

const RegInfo = struct {
    name: [:0]const u8,
    offset: comptime_int,
    access: AccessMode = .rw,
    struct_t: type = void,

    pub fn init(
        comptime name: [:0]const u8,
        comptime offset: comptime_int,
        comptime T: ?type
    ) RegInfo {
        return .{
            .name = name,
            .offset = offset,
            .struct_t = T orelse void
        };
    }
};

pub const BusWidth = enum(u2) {
    byte,
    word,
    dword,
    qword,
};

pub const AccessMode = enum(u2) {
    rw,
    ro,
    wo
};

pub inline fn reg(
    comptime name: [:0]const u8,
    comptime offset: comptime_int,
    comptime access: AccessMode,
) RegInfo {
    return RegInfo{
        .name = name,
        .offset = offset,
        .access = access,
        .struct_t = void
    };
}

pub inline fn regS(
    comptime name: [:0]const u8,
    comptime offset: comptime_int,
    comptime access: AccessMode,
    comptime StructT: type
) RegInfo {
    return RegInfo{
        .name = name,
        .offset = offset,
        .access = access,
        .struct_t = StructT
    };
}

pub fn RegsGroup(
    comptime group_name: [:0]const u8,
    comptime io_type: io.Type,
    comptime bus_width: BusWidth,
    comptime regs: []const RegInfo
) type {
    var fields: []const std.builtin.Type.EnumField = &.{};
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

    return struct {
        const Self = @This();

        pub const RegNames = @Type(reg_names);
        pub const name = group_name;

        base: usize,

        pub fn init(base_addr: usize) !Self {
            const result = switch (io_type) {
                .io_ports => .{ .base = base_addr },
                .mmio => .{ .base = vm.getVirtLma(base_addr) }
            };

            _ = io.request(name, base_addr, getGroupSize(), io_type) orelse return switch (io_type) {
                .io_ports => error.IoPortsBusy,
                .mmio => error.MmioBusy
            };

            return result;
        }

        const BusT = switch (bus_width) {
            .byte => u8,
            .word => u16,
            .dword => u32,
            .qword => u64
        };
        const Base = switch (io_type) {
            .io_ports => u16,
            .mmio => [*]BusT
        };

        const io_read = switch (io_type) {
            .io_ports => switch (bus_width) {
                .byte => io.inb,
                .word => io.inw,
                .dword => io.inl,
                .qword => @compileError("64-bit bus width unsupported with I/O ports")
            },
            .mmio => switch (bus_width) {
                .byte => io.readb,
                .word => io.readw,
                .dword => io.readl,
                .qword => io.readq
            }
        };
        const io_write = switch (io_type) {
            .io_ports => switch (bus_width) {
                .byte => io.outb,
                .word => io.outw,
                .dword => io.outl,
                .qword => @compileError("64-bit bus width unsupported with I/O ports")
            },
            .mmio => switch (bus_width) {
                .byte => io.writeb,
                .word => io.writew,
                .dword => io.writel,
                .qword => io.writeq
            }
        };

        fn RegStruct(comptime register: RegNames) type {
            return getReg(register).struct_t;
        }

        inline fn getGroupSize() usize {
            comptime var max_offset = 0;

            inline for (regs) |r| {
                if (r.offset > max_offset) max_offset = r.offset;
            }

            return switch (io_type) {
                .io_ports => max_offset + 1,
                .mmio => max_offset + @sizeOf(BusT)
            };
        }

        inline fn getBase(self: *const Self) Base {
            return switch (io_type) {
                .io_ports => @as(Base, @truncate(self.base)),
                .mmio => @as(Base, @ptrFromInt(self.base))
            };
        }

        inline fn getIdx(comptime offset: comptime_int) comptime_int {
            return offset / @sizeOf(BusT);
        }

        inline fn getReg(comptime register: RegNames) RegInfo {
            return regs[@intFromEnum(register)];
        }

        pub inline fn write(self: *const Self, comptime register: RegNames, value: BusT) void {
            @setRuntimeSafety(false);

            const reg_info = comptime getReg(register);
            if (comptime reg_info.access == .ro) {
                @compileError(std.fmt.comptimePrint(
                    "Register '{s}' for the '{s}' group is read only",
                    .{@tagName(register), name}
                ));
            }

            const offset = reg_info.offset;

            switch (io_type) {
                .io_ports => io_write(value, self.getBase() + offset),
                .mmio => io_write(@ptrCast(&self.getBase()[getIdx(offset)]), value)
            }
        }

        pub inline fn read(self: *const Self, comptime register: RegNames) BusT {
            @setRuntimeSafety(false);

            const reg_info = comptime getReg(register);
            if (comptime reg_info.access == .wo) {
                @compileError(std.fmt.comptimePrint(
                    "Register '{s}' of the '{s}' group is write only",
                    .{@tagName(register), name}
                ));
            }

            const offset = reg_info.offset;

            return switch (io_type) {
                .io_ports => return io_read(self.getBase() + offset),
                .mmio => return io_read(@ptrCast(&self.getBase()[getIdx(offset)]))
            };
        }

        pub inline fn set(self: *const Self, comptime register: RegNames, value: anytype) void {
            const reg_info = comptime getReg(register);

            if (reg_info.struct_t == void) @compileError("This register don't have a representation as user-defined struct");
            if (@TypeOf(value) != reg_info.struct_t) {
                @compileError(
                    "Value type must be: \"" ++ @typeName(reg_info.struct_t) ++
                    "\", found: \"" ++ @typeName(@TypeOf(value)) ++ "\""
                );
            }

            @setRuntimeSafety(false);

            const val = @as(BusT, @bitCast(value));
            self.write(register, val);
        }

        pub inline fn get(self: *const Self, comptime register: RegNames) RegStruct(register) {
            const reg_info = getReg(register);

            if (reg_info.struct_t == void) @compileError("This register don't have a representation as user-defined struct");

            @setRuntimeSafety(false);

            const val = self.read(register);
            return @as(reg_info.struct_t,  @bitCast(val));
        }
    };
}

test "type generating" {
    const Regs = RegsGroup(
        .mmio, .dword,
        &.{
            reg("foo", 0),
            reg("bar", 8)
        },
    );

    try std.testing.expect(@sizeOf(Regs) == @sizeOf(usize));

    try std.testing.expect(@hasField(Regs.RegNames, "foo"));
    try std.testing.expect(@hasField(Regs.RegNames, "bar"));
}

test "read mmio" {
    const Regs = RegsGroup(
        .mmio, .dword,
        &.{
            reg("foo", 0),
            reg("bar", @sizeOf(u32))
        },
    );
    const example_mmio = [_]u32{ 0xdeadbeef, 0xdeadc0de };
    const regs = Regs.init(@intFromPtr(&example_mmio));

    try std.testing.expect(regs.read(.foo) == example_mmio[0]);
    try std.testing.expect(regs.read(.bar) == example_mmio[1]);
}

test "write mmio" {
    const Regs = RegsGroup(
        .mmio, .dword,
        &.{
            reg("foo", 0),
            reg("bar", @sizeOf(u32))
        },
    );

    var example_mmio = [_]u32{ 0xdeadbeef, 0xdeadc0de };
    const regs = Regs.init(@intFromPtr(&example_mmio));

    try std.testing.expect(example_mmio[0] == 0xdeadbeef);
    try std.testing.expect(example_mmio[1] == 0xdeadc0de);

    regs.write(.foo, 0x1102);
    regs.write(.bar, 0x65565);

    try std.testing.expect(example_mmio[0] == 0x1102);
    try std.testing.expect(example_mmio[1] == 0x65565);
}