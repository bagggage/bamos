//! # PCI Configuration space access mechanisms

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const acpi = @import("../acpi.zig");
const bindings = @import("../../../bindings.zig");
const io = @import("../../io.zig");
const regs = @import("../../regs.zig");
const log = std.log.scoped(.@"pci.config");
const vm = @import("../../../vm.zig");

const config = @This();

pub const max_seg = 256;
pub const max_dev = 32;
pub const max_func = 8;

pub inline fn getBase(seg: u16, bus: u8, dev: u8, func: u8) usize {
    return bindings.getInstance().dev.pci.config.getBase(seg, bus, dev, func);
}

pub inline fn read(offset: usize) u32 {
    return bindings.getInstance().dev.pci.config.read(offset);
}

pub inline fn write(offset: usize, data: u32) void {
    bindings.getInstance().dev.pci.config.write(offset, data);
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
    _
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
    },
    serial_bus_controller: enum(u8) {
        firewire = 0x0,
        access_bus = 0x1,
        sas = 0x2,
        usb = 0x3,
        fibre_channel = 0x4,
        smbus = 0x5,
        infiniband = 0x6,
        ipmi_interface = 0x7,
        sata_controller = 0x8,
        usb3_controller = 0x9,

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

    pub const Bar32 = packed struct(u32) {
        type: Bar.Type,
        data: packed union {
            mmio: packed struct(u31) {
                type: enum(u2) { @"32bit" = 0, @"64bit" = 2, _ },
                prefetch: bool,
                address: u28,

                pub inline fn getBase(self: @This()) u32 {
                    return @as(u32, self.address) << 4;
                }
            },
            pio: packed struct(u31) {
                rsvd: u1,
                address: u30,

                pub inline fn getBase(self: @This()) u32 {
                    return @as(u32, self.address) << 2;
                }
            },
        },

        pub inline fn base(self: Bar32) u32 {
            return if (self.type == .mmio)
                    self.data.mmio.getBase()
                else
                    self.data.pio.getBase();
        }
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
        flattening_portal_bridge = 21,
        _
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

    pub inline fn init(base: usize, offset: u8) Capability {
        return bindings.getInstance().dev.pci.config.initCapability(base, offset);
    }

    pub inline fn next(self: *const Capability) ?Capability {
        if (self.header.next_offset == 0) return null;

        return Capability.init(self.base, self.header.next_offset);
    }

    pub inline fn as(self: *const Capability, comptime T: type) ConfigRegsFrom(T) {
        return .{ .dyn_base = self.base + self.offset };
    } 
};

pub const Bar = struct {
    pub const Type = enum(u1) { mmio = 0, pio = 1 };

    type: Type,
    is_64: bool = false,
    prefetch: bool = false,

    base: u64,
    size: u32,
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
    const info = @typeInfo(ConfigSpace.Layout);

    for (info.@"union".fields) |member| {
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
    null,
    null,
);

fn ConfigRegsFrom(comptime T: type) type {
    return regs.Group(ConfigIoMechanism, null, null, regs.from(T));
}

pub const ConfigSpace = struct {
    pub const Group = regs.Group(
        ConfigIoMechanism,
        null,
        null,
        regs.from(Layout),
    );

    const Layout = extern union {
        common: CommonHeader,
        device: DeviceConfig,
        device64: DeviceConfig64,
        p2p: Pci2PciConfig,
    };

    internal: Group,

    pub inline fn init(seg: u16, bus: u8, dev: u8, func: u8) ConfigSpace {
        return .{
            .internal = Group.initBase(
                config.getBase(seg, bus, dev, func),
            ) catch unreachable,
        };
    }

    pub inline fn read(self: *const ConfigSpace, offset: usize) u32 {
        return config.read(self.internal.dyn_base + offset);
    }

    pub inline fn write(self: *const ConfigSpace, offset: usize, data: u32) void {
        return config.write(self.internal.dyn_base + offset, data);
    }

    pub inline fn get(self: *const ConfigSpace, comptime field: anytype) FieldType(field) {
        return self.internal.read(field);
    }

    pub inline fn getAs(self: *const ConfigSpace, comptime T: type, comptime field: anytype) T {
        return self.internal.get(T, field);
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

    pub inline fn readBar(self: *const ConfigSpace, bar_idx: u3) Bar {
        return bindings.getInstance().pci.config.readBar(self, bar_idx);
    }
};

pub inline fn getMaxBus(seg: usize) usize {
    return bindings.getInstance().dev.pci.config.getMaxBus(seg);
}

pub inline fn getMaxSeg() usize {
    return max_seg;
}
