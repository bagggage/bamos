//! # Architecture-independent I/O subsytem

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = utils.arch;
const log = std.log.scoped(.@"dev.io");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub usingnamespace arch.io;

pub fn Mechanism(
    comptime AddrType: type, comptime DataType: type,
    comptime readFn: anytype, comptime writeFn: anytype,
    comptime initFn: ?fn(AddrType, AddrType) anyerror!AddrType
) type {
    comptime {
        const data_info = @typeInfo(DataType);

        if (data_info != .int or data_info.int.signedness == .signed or data_info.int.bits % 8 != 0)
            @compileError("Data type must be an unsigned integer e.g. `u<x>`, where x - number of bits: 8, 16, 32, 64");

        const addr_info = @typeInfo(AddrType);

        if (addr_info != .int or addr_info.int.signedness != .unsigned)
            @compileError("Address type must be an unsigned integer e.g `u<x>`, where x - number of bits");

        const read_info = @typeInfo(@TypeOf(readFn));
        const write_info = @typeInfo(@TypeOf(writeFn));

        if (
            read_info != .@"fn" or write_info != .@"fn" or
            write_info.@"fn".return_type != void or
            read_info.@"fn".return_type != DataType or
            read_info.@"fn".params.len != 1 or write_info.@"fn".params.len != 2 or
            write_info.@"fn".params[0].type != AddrType or write_info.@"fn".params[1].type != DataType or
            read_info.@"fn".params[0].type != AddrType
        ) {
            @compileError("Read/Write must be a functions: `fn read(AddrType) DataType` and `fn write(AddrType, DataType) void`");
        }
    }

    return struct {
        pub const Address = AddrType;
        pub const Data = DataType;

        pub const init = initFn;

        pub inline fn read(address: Address) Data {
            return readFn(address);
        }

        pub inline fn write(address: Address, data: Data) void {
            return writeFn(address, data);
        }
 
        pub inline fn readNonUniform(comptime IntType: type, base: AddrType, comptime bit_offset: u16) IntType {
            @setRuntimeSafety(false);

            const NonUniformDataType = IntType;

            comptime {
                const data_info = @typeInfo(NonUniformDataType);
                if (data_info != .int and data_info != .comptime_int)
                    @compileError("Invalid non-uniform data type: "++@typeName(IntType)++", must be an integer");
            }

            const bit_size = comptime @bitSizeOf(NonUniformDataType);
            const data_size = comptime @sizeOf(DataType);
            const data_bit_size = comptime @bitSizeOf(DataType);
            
            const begin = comptime (bit_offset / data_bit_size);
            const end = comptime ((bit_offset + bit_size - 1) / data_bit_size);

            const begin_offset = comptime begin * data_size;
            const offset = comptime (bit_offset % data_bit_size);
            const len = comptime (end - begin + 1);

            comptime var bit_shift: u8 = 0;
            var readed: NonUniformDataType = undefined;

            inline for (0..len) |i| {
                const idx: comptime_int = i;
                const byte_offset = comptime idx * data_size;

                const temp_readed = read(base +% begin_offset + byte_offset);

                if (comptime i == 0) {
                    readed = cast(NonUniformDataType, temp_readed >> offset);
                    bit_shift = comptime (if (bit_size < data_bit_size) data_bit_size - bit_size else bit_size - data_bit_size) + offset;
                }
                else {
                    readed |= cast(NonUniformDataType, temp_readed) << @truncate(bit_shift);
                    bit_shift += data_bit_size;
                }
            }

            return readed;
        }

        pub inline fn writeNonUniform(base: AddrType, comptime bit_offset: u16, data: anytype) void {
            @setRuntimeSafety(false);

            const NonUniformDataType = @TypeOf(data);

            comptime {
                const data_info = @typeInfo(NonUniformDataType);
                if (data_info != .int and data_info != .comptime_int)
                    @compileError("Invalid non-uniform data type: "++@typeName(NonUniformDataType)++", must be an integer");
            }

            const bit_size = comptime @bitSizeOf(NonUniformDataType);
            const data_size = comptime @sizeOf(DataType);
            const data_bit_size = comptime @bitSizeOf(DataType);
            
            const begin = comptime (bit_offset / data_bit_size);
            const end = comptime ((bit_offset + bit_size - 1) / data_bit_size);

            const offset = comptime (bit_offset % data_bit_size);
            const len = comptime (end - begin + 1);

            const begin_base = base +% comptime (begin * data_size);

            if (comptime (bit_size % data_bit_size) == 0 and (offset == 0)) {
                inline for (0..len) |i| {
                    const idx: comptime_int = i;
                    const bit_shift = comptime (idx * data_bit_size);

                    write(begin_base + (comptime idx * data_size), cast(DataType, data >> bit_shift));
                }
            }
            else {
                var to_write = data;

                inline for(0..len) |i| {
                    const idx: comptime_int = i;
                    const byte_offset = comptime idx * data_size;

                    if (comptime i == 0) {
                        const bitmask = comptime (@as(DataType, 1) << offset) -% 1;

                        const readed = if (comptime len == 1) blk: {

                            const end_bitmask = comptime cast(DataType, (@as(usize, 0) -% 1) << (offset + bit_size));
                            break :blk read(begin_base) & (comptime bitmask | end_bitmask);
                        } else read(begin_base) & bitmask;

                        write(begin_base, readed | (cast(DataType, to_write) << offset));

                        to_write >>= @truncate(data_bit_size - offset);
                    }
                    else if (comptime i == len - 1) {
                        const tail_bits = comptime (bit_size + offset) % data_size;
                        const end_bitmask = comptime cast(DataType, (@as(usize, 0) -% 1) << tail_bits);

                        const readed = read(begin_base) & end_bitmask;
                        write(begin_base + byte_offset, readed | cast(DataType, data));
                    }
                    else {
                        write(begin_base + byte_offset, cast(DataType, data));
                    }
                }
            }
        }

        inline fn cast(comptime T: type, val: anytype) T {
            return if (@bitSizeOf(T) < @bitSizeOf(@TypeOf(val)))
                @truncate(val) else val;
        }
    };
}

pub fn BusDataType(comptime bus_width: BusWidth) type {
    return switch (bus_width) {
        .byte => u8,
        .word => u16,
        .dword => u32,
        .qword => u64
    };
}

pub fn IoPortsMechanism(comptime name: [:0]const u8, comptime bus_width: BusWidth) type {
    return Mechanism(
        u16, BusDataType(bus_width),
        switch (bus_width) {
            .byte => arch.io.inb,
            .word => arch.io.inw,
            .dword => arch.io.inl,
            .qword => @compileError("64-bit bus width unsupported with I/O ports")
        },
        switch (bus_width) {
            .byte => arch.io.outb,
            .word => arch.io.outw,
            .dword => arch.io.outl,
            .qword => unreachable
        },
        struct {
            fn init(base: u16, size: u16) !u16 {
                return @truncate(request(name, base, size, .io_ports) orelse return error.IoBusy);
            }
        }.init
    );
}

pub fn MmioMechanism(comptime name: [:0]const u8, comptime bus_width: BusWidth) type {
    return Mechanism(
        usize, BusDataType(bus_width),
        switch (bus_width) {
            .byte => readb,
            .word => readw,
            .dword => readl,
            .qword => readq
        },
        switch (bus_width) {
            .byte => writeb,
            .word => writew,
            .dword => writel,
            .qword => writeq
        },
        struct {
            fn init(base: usize, size: usize) !usize {
                _ = request(name, base, size, .mmio) orelse return error.MmioBusy;
                return vm.getVirtLma(base);
            }
        }.init
    );
}

pub const BusWidth = enum(u2) {
    byte,
    word,
    dword,
    qword
};

pub const Type = enum(u1) {
    mmio,
    io_ports
};

const Region = packed struct {
    name: [*:0]const u8,
    base: usize,
    end: usize,

    pub fn format(self: *const Region, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}: 0x{x}-0x{x}", .{self.name, self.base, self.end - 1});
    }
};
const RegionList = utils.SList(Region);
const RegionNode = RegionList.Node;

var lock = utils.Spinlock.init(.unlocked);
var region_oma = vm.ObjectAllocator.init(RegionNode);

var ports_list = RegionList{};
var mmio_list = RegionList{};

inline fn getIoList(comptime io_type: Type) *RegionList {
    return switch (io_type) {
        .io_ports => &ports_list,
        .mmio => &mmio_list
    };
}

fn writeMmioFn(comptime AddrType: type, comptime DataType: type)
    fn (address: AddrType, data: DataType) callconv(.Inline) void
{
    return struct {
        pub inline fn write(address: AddrType, data: DataType) void {
            @setRuntimeSafety(false);
            const ptr = switch (@typeInfo(AddrType)) {
                .comptime_int, .int => @as(*volatile DataType, @ptrFromInt(address)),
                .pointer => @as(*volatile DataType, @ptrCast(address)),
                else => @compileError("Invalid address type")
            };
            ptr.* = std.mem.nativeToLittle(DataType, data);
        }
    }.write;
}

fn readMmioFn(comptime AddrType: type, comptime DataType: type)
    fn (address: AddrType) callconv(.Inline) DataType
{
    return struct {
        pub inline fn read(address: AddrType) DataType {
            @setRuntimeSafety(false);
            const ptr = switch (@typeInfo(AddrType)) {
                .comptime_int, .int => @as(*const volatile DataType, @ptrFromInt(address)),
                .pointer => @as(*const volatile DataType, @ptrCast(address)),
                else => @compileError("Invalid address type")
            };
            return std.mem.littleToNative(DataType, ptr.*);
        }
    }.read;
}

/// Write byte into mmio memory.
pub const writeb = writeMmioFn(usize, u8);
/// Write word into mmio memory.
pub const writew = writeMmioFn(usize, u16);
/// Write double word into mmio memory.
pub const writel = writeMmioFn(usize, u32);
/// Write quad word into mmio memory.
pub const writeq = writeMmioFn(usize, u64);

/// Read byte from mmio memory.
pub const readb = readMmioFn(usize, u8);
/// Read word from mmio memory.
pub const readw = readMmioFn(usize, u16);
/// Read double word from mmio memory.
pub const readl = readMmioFn(usize, u32);
/// Read quad word from mmio memory.
pub const readq = readMmioFn(usize, u64);

pub fn request(comptime name: [:0]const u8, base: usize, size: usize, comptime io_type: Type) ?usize {
    const end = base + size;

    const list = getIoList(io_type);

    {
        lock.lock();
        defer lock.unlock();

        var temp = list.first;

        while (temp) |node| : (temp = node.next) {
            const region = &node.data;

            if (region.end <= base or region.base >= end) continue;

            return null;
        }

        const new_region = region_oma.alloc(RegionNode) orelse return null;
        new_region.* = RegionNode{
            .data = .{ .base = base, .end = end, .name = name }
        };

        list.prepend(new_region);
    }

    log.debug("{s: <8}: {s: <12} 0x{x}-0x{x}", .{@tagName(io_type), name, base, base + size - 1});

    return base;
}

pub fn release(base: usize, comptime io_type: Type) void {
    const list = getIoList(io_type);

    lock.lock();
    defer lock.unlock();

    var temp = list.first;

    while (temp) |node| : (temp = node.next) {
        const region = &node.data;

        if (region.base == base) {
            list.remove(node);
            region_oma.free(node);
            
            return;
        }
    }

    unreachable;
}

pub fn isAvail(base: usize, size: usize, comptime io_type: Type) bool {
    const end = base + size;

    lock.lock();
    defer lock.unlock();

    var temp = getIoList(io_type).first;

    while (temp) |node| : (temp = node.next) {
        const region = &node.data;

        if (region.end <= base or region.base >= end) continue;

        return false;
    }

    return true;
}