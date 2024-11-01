//! # PCI Configuration space access mechanisms

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

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

pub const ecam_enabled = true;

const PortsIo = struct {
    /// I/O Ports addresses used for accessing
    /// PCI config. space on x86/x86-64 when
    /// mmio (PCI-Express) is unavailable.
    const x86_io_addr = 0xCF8;
    const x86_io_data = 0xCFC;

    const x86_base_offset = 0x80000000;

    const config_size = 256;

    const Ports = regs.Group(
        io.IoPortsMechanism("PCI config I/O ports", .dword),
        x86_io_addr, null, &.{
            regs.reg("CONFIG_ADDR", 0x0, null, .write),
            regs.reg("CONFIG_DATA", 0x4, null, .rw),
    });

    const ports = Ports{};

    pub fn read(offset: usize) u32 {
        @setRuntimeSafety(false);

        ports.write(.CONFIG_ADDR, @truncate(offset));
        return ports.read(.CONFIG_DATA);
    }

    pub fn write(offset: usize, data: u32) void {
        @setRuntimeSafety(false);

        ports.write(.CONFIG_ADDR, @truncate(offset));
        ports.write(.CONFIG_DATA, data);
    }

    pub fn getBase(_: u16, bus: u8, dev: u8, func: u8) usize {
        return x86_base_offset | (@as(u32, bus) << 16 | @as(u32, dev) << 11 | @as(u32, func) << 8);
    }
};

const MmioIo = struct {
    pub const config_size = 4096; 

    pub fn read(offset: usize) u32 {
        @setRuntimeSafety(false);
        return io.readl(offset);
    }

    pub fn write(offset: usize, data: u32) void {
        @setRuntimeSafety(false);
        io.writel(offset, data);
    }

    pub fn getBase(seg: u16, bus: u8, dev: u8, func: u8) usize {
        const phys: usize = @truncate(mcfg.?.entries()[seg].base);
        const base = vm.getVirtLma(phys);

        return base | (@as(u32, bus) << 20 | @as(u32, dev) << 15 | @as(u32, func) << 12);
    }
};

const AnyIo = struct {
    read: *const fn (offset: usize) u32 = undefined,
    write: *const fn (offset: usize, data: u32) void = undefined,

    getBase: *const fn (seg: u16, bus: u8, dev: u8, func: u8) usize = undefined,
};

const IoType = switch(builtin.cpu.arch) {
    .x86,
    .x86_64 => AnyIo,
    else => MmioIo
};

const Mcfg = extern struct {
    header: acpi.SdtHeader,
    reserved: u64 align(4),

    const Entry = extern struct {
        base: u64 align(4),
        segment: u16,

        start_bus: u8,
        end_bus: u8,
    
        reserved: u32,
    };

    comptime {
        std.debug.assert(@sizeOf(Entry) == 16);
        std.debug.assert(@sizeOf(Mcfg) == 44);
    }

    pub inline fn entries(self: *const Mcfg) []const Entry {
        const ptr: [*]const Entry = @ptrFromInt(@intFromPtr(self) + @sizeOf(Mcfg));
        const len = (self.header.length - @sizeOf(acpi.SdtHeader)) / @sizeOf(Entry);

        return ptr[0..len];
    }
};

pub fn init() !void {
    const entry = acpi.findEntry("MCFG");

    if (IoType == AnyIo) {
        // Always reserve I/O ports region to prevent access even with MMIO.
        _ = try PortsIo.Ports.init();

        if (ecam_enabled and entry != null and entry.?.checkSum()) {
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

pub inline fn write(offset: usize, data: u32) void {
    cfg_io.write(offset, data);
}

const CommonHeader = extern struct {
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

const DeviceConfig = extern struct {
    _header: CommonHeader,

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

const DeviceConfig64 = extern struct {
    _header: CommonHeader,

    bar0_64: u64,
    bar1_64: u64,
    bar2_64: u64,
};

const Pci2PciConfig = extern struct {
    _header: CommonHeader,
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

pub const ClassCode = enum(u8) {
    unclassified = 0x0,
    mass_storage_controller = 0x1,
    network_controller = 0x2,
    display_controller = 0x3,
    multimedia_controller = 0x4,
    memory_controller = 0x5,
    bridge = 0x6,
    simple_comm_controller = 0x7,
    base_system_peripheral = 0x8,
    input_dev_controller = 0x9,
    docking_station = 0xA,
    processor = 0xB,
    serial_bus_controller = 0xC,
    wireless_controller = 0xD,
    intelligent_controller = 0xE,
    satellite_comm_contrller = 0xF,
    encryption_controller = 0x10,
    signal_proc_controller = 0x11,
    proc_accelerator = 0x12,
    non_essential_instrum = 0x13,
    co_processor = 0x40,
    vendor_specific = 0xFF
};

pub const SubclassCode = extern union {
    unclassified: enum(u8) {
        non_vga_unclass_dev = 0x0,
        vga_unclass_dev = 0x1,

        other = 0x80
    },
    mass_storage_device: enum(u8) {
        scsi_bus_controller = 0x0,
        ide_controller = 0x1,
        floppy_disk_controller = 0x2,
        ipi_bus_controller = 0x3,
        raid_controller = 0x4,
        ata_controller = 0x5,
        sata_controller = 0x6,
        serial_scsi_controller = 0x7,
        non_volatile_mem_controller = 0x8,

        other = 0x80
    },
    network_controller: enum(u8) {
        ethernet_controller = 0x0,
        token_ring_controller = 0x1,
        fddi_controller = 0x2,
        atm_controller = 0x3,
        isdn_controller = 0x4,
        worldfip_controller = 0x5,
        picmg_multi_comp_controller = 0x6,
        infiniband_controller = 0x7,
        fabric_controller = 0x8,

        other = 0x80
    },
    display_controller: enum(u8) {
        vga_compat_controller = 0x0,
        xga_controller = 0x1,
        three_d_controller = 0x2,

        other = 0x80
    },
    multimedia_controller: enum(u8) {
        video_controller = 0x0,
        audio_controller = 0x1,
        comp_telephony_device = 0x2,
        audio_device = 0x3,

        other = 0x80
    },
    mem_controller: enum(u8) {
        ram_controller = 0x0,
        flash_controller = 0x1,

        other = 0x80
    },
    bridge: enum(u8) {
        host_bridge = 0x0,
        isa_bridge = 0x1,
        eisa_bridge = 0x2,
        mca_bridge = 0x3,
        pci_to_pci_bridge_0x4 = 0x4,
        pcmcia_bridge = 0x5,
        nubus_bridge = 0x6,
        cardbus_bridge = 0x7,
        raceway_bridge = 0x8,
        pci_to_pci_bridge_0x9 = 0x9,
        inf_to_pci_host_bridge = 0xa,

        other = 0x80
    }
};

pub const Regs = struct {
    pub const Command = packed struct {
        io_space: u1,
        mem_space: u1,
        bus_master: u1,
        spec_cycles: u1,
        mem_write_inval: u1,
        vga_palette_snoop: u1,
        parity_error: u1,
        rsrvd: u1,
        serr_enable: u1,
        fast_btb: u1,
        intr_disable: u1,

        rsrvd_1: u5
    };
};

pub const Capability = struct {
    pub const Id = enum(u8) {
        none = 0,
        power_mngmt_interface = 1,
        agp = 2,
        vpd = 3,
        slot_id = 4,
        msi = 5,
        comp_pci_hot_swap = 6,
        pci_x = 7,
        hyper_transport = 8,
        venodor_specific = 9,
        debug_port = 10,
        cmp_pci_central_res_ctrl = 11,
        hot_plug = 12,
        bridge_subsys_ven_id = 13,
        agp_8x = 14,
        secure_device = 15,
        pci_express = 16,
        msi_x = 17,
        sata_data_idx_conf = 18,
        advanced_feat = 19,
        enhanced_alloc = 20,
        flattening_portal_bridge = 21
    };

    /// MSI layouts namespace
    pub const Msi = struct {
        /// Message control register layout
        pub const MessageControl = packed struct {
            enable: u1,
            multi_msg: u3,
            multi_msg_enable: u3,
            x64_addr: u1,
            per_vec_mask: u1,

            _rsrvd: u7
        };

        /// MSI layout with 32-bit message address
        pub const x32 = packed struct {
            _header: Header,

            msg_ctrl: u16,
            msg_addr: u32,

            msg_data: u16,
            _rsrvd: u16,

            mask_bits: u32,
            pending_bits: regs.ReadOnlyP(u32)
        };
        /// MSI layout with 64-bit message address
        pub const x64 = packed struct {
            _header: Header,

            msg_ctrl: u16,
            msg_addr: u64,

            msg_data: u16,
            _rsrvd: u16,

            mask_bits: u32,
            pending_bits: regs.ReadOnlyP(u32)
        };
    };

    /// MSI-X layout
    pub const MsiX = packed struct {
        /// Message control register layout
        pub const MessageControl = packed struct {
            table_size: u11,
            _rsrvd: u3,

            func_mask: u1,
            enable: u1,
        };

        _header: Header,
        msg_ctrl: u16,

        table_offset: regs.ReadOnlyP(u32),
        pba_offset: regs.ReadOnlyP(u32)
    };

    const Header = packed struct {
        id: Id,
        next_offset: u8,
    };

    header: Header,
    offset: u8,
    base: usize,

    pub fn init(base: usize, offset: u8) Capability {
        const temp = cfg_io.read(base + offset);
        const header: Capability.Header = @bitCast(@as(u16, @truncate(temp)));

        return .{
            .header = header,
            .offset = offset,
            .base = base
        };
    }

    pub inline fn next(self: *const Capability) ?Capability {
        if (self.header.next_offset == 0) return null;

        return Capability.init(self.base, self.header.next_offset);
    }

    pub inline fn as(self: *const Capability, comptime T: type) ConfigRegsFrom(T) {
        return .{ .dyn_base = self.base + self.offset };
    } 
};

const ConfigSpaceLayout = extern union {
    common: CommonHeader,
    device: DeviceConfig,
    device64: DeviceConfig64,
    p2p:    Pci2PciConfig,
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

    cap_ptr,

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
    const info = @typeInfo(ConfigSpaceLayout);

    for (info.Union.fields) |member| {
        if (@hasField(member.type, field_name)) {
            return member.type;
        }
    }

    @compileError("Invalid configuration space field");
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

const ConfigIoMechanism = io.Mechanism(
    usize, u32,
    read,
    write,
    null
);

fn ConfigRegsFrom(comptime T: type) type {
    return regs.Group(ConfigIoMechanism, null, null, regs.from(T));
}

pub const ConfigSpaceGroup = regs.Group(
    ConfigIoMechanism, null, null,
    regs.from(ConfigSpaceLayout)
);

pub const ConfigSpace = struct {
    internal: ConfigSpaceGroup,

    pub inline fn init(seg: u16, bus: u8, dev: u8, func: u8) ConfigSpace {
        return .{ .internal = ConfigSpaceGroup.initBase(cfg_io.getBase(seg, bus, dev, func)) catch unreachable };
    }

    pub inline fn read(self: *const ConfigSpace, offset: usize) u32 {
        return cfg_io.read(self.internal.dyn_base + offset);
    }

    pub inline fn write(self: *const ConfigSpace, offset: usize, data: u32) void {
        return cfg_io.write(self.internal.dyn_base + offset, data);
    }

    pub inline fn get(self: *const ConfigSpace, comptime field: anytype) FieldType(field) {
        return self.internal.read(field);
    }

    pub inline fn getAs(self: *const ConfigSpace, comptime T: type, comptime field: anytype) T {
        return  self.internal.get(T, field);
    }

    pub inline fn set(self: *const ConfigSpace, comptime field: anytype, value: FieldType(field)) void {
        self.internal.write(field, value);
    }

    pub inline fn setAs(self: *const ConfigSpace, comptime field: anytype, value: anytype) void {
        self.internal.set(field, value);
    }

    pub fn getCapabilities(self: *const ConfigSpace) ?Capability {
        if ((self.get(.status) & 0b10000) == 0) return null;

        const cap_ptr = self.get(.cap_ptr);

        return Capability.init(self.internal.dyn_base, cap_ptr);
    }

    pub fn readBar(self: *const ConfigSpace, bar_idx: u3) usize {
        const base = @offsetOf(DeviceConfig, "bar0") + (@as(usize, bar_idx) * @sizeOf(u32));
        const bar_l = self.read(base);

        // Is 64-bit ?
        if ((bar_l & 0x7) == 0b100) {
            const bar_h = self.read(base + @sizeOf(u32));
            return (@as(u64, bar_h) << @bitSizeOf(u32)) | (bar_l & 0xFFFF_FFF0);
        }
        else {
            return bar_l & 0xFFFF_FFFC;
        }
    }
};

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

        _ = io.request("PCI config mmio", entry.base, config_space_size, .mmio) orelse
            return error.IoRegionBusy;
    }

    log.info("PCI config. space: mmio: 0x{x}: max seg: {}", .{entries[0].base, max_seg});
}