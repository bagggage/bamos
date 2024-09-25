//! ## PCI Configuration space access mechanisms

const std = @import("std");
const builtin = @import("builtin");

const acpi = @import("../acpi.zig");
const io = @import("../../io.zig");
const regs = @import("../../regs.zig");
const log = @import("../../../log.zig");
const utils = @import("../../../utils.zig");
const vm = @import("../../../vm.zig");

var cfg_io: IoType = undefined;
var mcfg: ?*const Mcfg = null;

var max_seg: usize = 1;

const max_bus = 256;

pub const max_dev = 32;
pub const max_func = 8;

const PortsIo = struct {
    /// I/O Ports addresses used for accessing
    /// PCI config. space on x86/x86-64 when
    /// mmio (PCI-Express) is unavailable.
    const x86_io_addr = 0xCF8;
    const x86_io_data = 0xCFC;

    const x86_base_offset = 0x80000000;

    const config_size = 256;

    pub fn read(offset: usize) u32 {
        io.outl(@truncate(offset), x86_io_addr);
        return io.inl(x86_io_data);
    }

    pub fn write(data: u32, offset: usize) void {
        io.outl(@truncate(offset), x86_io_addr);
        io.outl(data, x86_io_data);
    }

    pub fn getBase(_: u16, bus: u8, dev: u8, func: u8) usize {
        return x86_base_offset | (@as(u32, bus) << 16 | @as(u32, dev) << 11 | @as(u32, func) << 8);
    }
};

const MmioIo = struct {
    pub const config_size = 4096; 

    pub fn read(offset: usize) u32 {
        return io.readl(@ptrFromInt(offset));
    }

    pub fn write(data: u32, offset: usize) void {
        io.writel(@ptrFromInt(offset), data);
    }

    pub fn getBase(seg: u16, bus: u8, dev: u8, func: u8) usize {
        const phys: usize = @truncate(mcfg.?.entries()[seg].base);
        const base = vm.getVirtLma(phys);

        return base | (@as(u32, bus) << 20 | @as(u32, dev) << 15 | @as(u32, func) << 12);
    }
};

const AnyIo = struct {
    read: *const fn (offset: usize) u32 = undefined,
    write: *const fn (data: u32, offset: usize) void = undefined,

    getBase: *const fn (seg: u16, bus: u8, dev: u8, func: u8) usize = undefined,
};

const IoType = switch(builtin.cpu.arch) {
    .x86,
    .x86_64 => AnyIo,
    else => MmioIo
};

const Mcfg = extern struct {
    header: acpi.SdtHeader,
    reserved: [2]u32,

    _entries: Entry,

    const Entry = extern struct {
        base: u64 align(4),
        segment: u16, 

        start_bus: u8,
        end_bus: u8,
    
        reserved: [4]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(Entry) == 16);
        std.debug.assert(@sizeOf(Mcfg) == 44 + @sizeOf(Entry));
    }

    pub inline fn entries(self: *const Mcfg) []const Entry {
        const ptr: [*]const Entry = @ptrCast(&self._entries);
        const len = (self.header.length - @sizeOf(acpi.SdtHeader)) / @sizeOf(Entry);

        return ptr[0..len];
    }
};

pub fn init() !void {
    const entry = acpi.findEntry("MCFG");

    if (IoType == AnyIo) {
        // Always reserve I/O ports region to prevent access even with MMIO.
        _ = io.request("PCI Config I/O ports", PortsIo.x86_io_addr, 8, .io_ports) orelse
            return error.IoRegionsBusy;

        if (entry != null and entry.?.checkSum()) {
            cfg_io.read = MmioIo.read;
            cfg_io.write = MmioIo.write;
            cfg_io.getBase = MmioIo.getBase;

            try initMmio(entry.?);
        }
        else {
            cfg_io.read = PortsIo.read;
            cfg_io.write = PortsIo.write;
            cfg_io.getBase = PortsIo.getBase;

            log.info("PCI config. space: i/o ports", .{});
        }
    }
    else if (entry) |hdr| {
        if (!hdr.checkSum()) return error.McfgInvalidChecksum;

        try initMmio(hdr);
    }
    else {
        return error.McfgEntryNotFound;
    }
}

pub inline fn getBase(seg: u16, bus: u8, dev: u8, func: u8) usize {
    return cfg_io.getBase(seg, bus, dev, func);
}

pub inline fn read(offset: usize) u32 {
    return cfg_io.read(offset);
}

pub inline fn write(data: u32, offset: usize) void {
    cfg_io.write(data, offset);
}

const CommonHdr = extern struct {
    vendor_id: u16,
    device_id: u16,

    command: u16,
    status: u16,

    revision_id: u8,
    prog_if: u8,
    subclass: u8,
    class_code: u8,

    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,
};

const DeviceHdr = extern struct {
    _header: CommonHdr,

    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,

    cardbus_cis_ptr: u32,

    subsys_ven_id: u16,
    subsys_id: u16,

    expans_rom_base: u32,

    cap_ptr: u8,
    _0: [3]u8,

    _1: u32,

    intr_line: u8,
    intr_pin: u8,
    min_grant: u8,
    max_latency: u8,
};

const Pci2PciHdr = extern struct {
    _header: CommonHdr,
    _0: [2]u32,

    prim_bus_num: u8,
    sec_bus_num: u8,
    subord_bus_num: u8,
    sec_late_timer: u8,

    io_base: u8,
    io_limit: u8,
    sec_status: u16,

    mem_base: u16,
    mem_limit: u16,

    pref_mem_base: u16,
    pref_mem_limit: u16,

    pref_mem_base_h: u32,
    pref_mem_limit_h: u32,

    io_base_h: u16,
    io_limit_h: u16,

    _1: [2]u32,

    _2: u16,
    bridge_ctrl: u16
};

const ConfigSpaceHeader = extern union {
    common: CommonHdr,
    device: DeviceHdr,
    p2p:    Pci2PciHdr,
};

const Fields = enum {
    // Common
    vendor_id,
    device_id,

    command,
    status,

    revision_id,
    prog_if,
    subclass,
    class_code,

    cache_line_size,
    latency_timer,
    header_type,
    bist,

    // Device header
    bar0,
    bar1,
    bar2,
    bar3,
    bar4,
    bar5,

    bar0_64,
    bar1_64,
    bar2_64,

    cardbus_cis_ptr,

    subsys_ven_id,
    subsys_id,

    expans_rom_base,

    cap_offset,

    intr_line,
    intr_pin,
    min_grant,
    max_latency,

    // Pci2Pci bridge header
    prim_bus_num,
    sec_bus_num,
    subord_bus_num,
    sec_late_timer,

    io_base,
    io_limit,

    sec_status,

    mem_base,
    mem_limit,

    pref_mem_base,
    pref_mem_limit,

    pref_mem_base_h,
    pref_mem_limit_h,

    io_base_h,
    io_limit_h,
    bridge_ctrl
};

fn FieldMember(comptime field: Fields) type {
    const field_name = @tagName(field);

    if (comptime std.mem.endsWith(u8, field_name, "_64")) {
        return DeviceHdr;
    }

    const info = @typeInfo(ConfigSpaceHeader);

    for (info.Union.fields) |member| {
        if (@hasField(member.type, field_name)) {
            return member.type;
        }
    }

    @compileError("Invalid field");
}

fn FieldType(comptime field: Fields) type {
    const field_name = @tagName(field);

    if (comptime std.mem.endsWith(u8, field_name, "_64")) {
        return u64;
    }

    const layout: FieldMember(field) = undefined;

    return @TypeOf(@field(layout, field_name));
}

const Self = @This();

pub const ConfigSpace = struct {
    base: usize,

    pub inline fn init(seg: u16, bus: u8, dev: u8, func: u8) ConfigSpace {
        return .{ .base = cfg_io.getBase(seg, bus, dev, func) };
    }

    pub inline fn get(self: *const ConfigSpace, comptime field: Fields) FieldType(field) {
        return Self.get(self.base, field);
    }

    pub inline fn set(self: *ConfigSpace, comptime field: Fields, value: FieldType(field)) void {
        return Self.set(self.base, field, value);
    }
};

pub inline fn get(base: usize, comptime field: Fields) FieldType(field) {
    const Member = FieldMember(field);
    const field_name = @tagName(field);

    if (comptime std.mem.endsWith(u8, field_name, "_64")) {
        // Read BAR*_64
        const bar_idx = field_name[3] - '0';

        const base_offset = @offsetOf(Member, "bar0");
        const offset = base_offset + (@sizeOf(u64) * bar_idx);

        return @as(u64, read(offset)) | (@as(u64, read(offset + @sizeOf(u32))) << @bitSizeOf(u32));
    }
    else {
        const offset = @offsetOf(Member, field_name);

        const inner_offset = offset % @sizeOf(u32);
        const aligned_offset = offset - inner_offset;

        const value = read(base | aligned_offset);

        return @truncate(value >> (inner_offset * utils.byte_size));
    }
}

pub inline fn set(base: usize, comptime field: Fields, value: FieldType(field)) void {
    const Member = FieldMember(field);
    const Type = FieldType(field);

    const offset = @offsetOf(Member, @tagName(field));

    if (Type == u32) {
        write(value, base | offset);
    }
    else {
        const inner_offset = offset % @sizeOf(u32);
        const aligned_offset = offset - inner_offset;

        const data = (
            read(base | aligned_offset) |
            @as(u32, value) << (inner_offset * utils.byte_size)
        );

        write(data, base | aligned_offset);
    }
}

pub inline fn getMaxBus(seg: usize) usize {
    if (IoType == AnyIo) {
        return if (mcfg != null) (@as(usize, mcfg.?.entries()[seg].end_bus) + 1) else max_bus;
    }

    return mcfg.?.entries()[seg].end_bus + 1;
}

pub inline fn getMaxSeg() usize {
    return max_seg;
}

fn initMmio(mcfg_hdr: *const acpi.SdtHeader) !void {
    mcfg = @ptrCast(mcfg_hdr);

    const entries = mcfg.?.entries();
    max_seg = entries.len;

    for (entries) |entry| {
        const config_space_size = (@as(usize, entry.end_bus - entry.start_bus) + 1) * 4096 * max_dev * max_func;

        _ = io.request("PCI Config mmio", entry.base, config_space_size, .mmio) orelse
            return error.IoRegionBusy;
    }

    log.info("PCI config. space: mmio: 0x{x}: max seg: {}", .{entries[0].base, max_seg});
}