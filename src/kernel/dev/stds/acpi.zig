const std = @import("std");

const boot = @import("../../boot.zig");
const dev = @import("../../dev.zig");
const io = @import("../io.zig");
const smp = @import("../../smp.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");

pub const timer = @import("../drivers/timer/acpi_timer.zig");

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 36);
        std.debug.assert(@alignOf(@This()) == @alignOf(u32));
    }

    pub fn checkSum(self: *const SdtHeader) bool {
        if (self.length == 0) return false;

        const ptr: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;

        for (0..self.length) |i| { sum +%= ptr[i]; }

        return sum == 0;
    }
};

pub const Xsdt = extern struct {
    header: SdtHeader,
    _entries: *SdtHeader align(4),

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(SdtHeader) + @sizeOf(*SdtHeader));
    }

    pub inline fn entries(self: *Xsdt) []align(4) *SdtHeader {
        const len = (self.header.length - @sizeOf(SdtHeader)) / @sizeOf(@TypeOf(self._entries));
        return @as([*]align(4) *SdtHeader, @ptrCast(&self._entries))[0..len];
    }
};

pub const Fadt = extern struct {
    header: SdtHeader,

    fw_ctrl: u32,
    dsdt: u32,

    reserved_0: u8,
    pref_pw_mgmt_profile: enum(u8) {
        unspecified = 0,
        desktop = 1,
        mobile = 2,
        workstation = 3,
        enterprise_server = 4,
        soho_server = 5,
        aplliance_pc = 6,
        performance_server = 7,
        _
    },

    sci_interrupt: u16,
    smi_cmd_port: u32,

    acpi_enable: u8,
    acpi_disable: u8,

    s4bios_req: u8,
    pstate_ctrl: u8,

    pm1a_event_blk: u32,
    pm1b_event_blk: u32,
    pm1a_ctrl_blk: u32,
    pm1b_ctrl_blk: u32,
    pm2_ctrl_blk: u32,
    pm_timer_blk: u32,

    gpe0_block: u32,
    gpe1_block: u32,

    pm1_event_len: u8,
    pm1_ctrl_len: u8,
    pm2_ctrl_len: u8,
    pm_timer_len: u8,

    gpe0_len: u8,
    gpe1_len: u8,
    gpe1_base: u8,
    cstate_ctrl: u8,

    worst_c2_latency: u16,
    worst_c3_latency: u16,

    flush_size: u16,
    flush_stride: u16,

    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    month_alarm: u8,

    century: u8,

    iapc_boot_arch: u16 align(1),
    reserved_1: u8,

    flags: u32,

    reset_reg: GenericAddrStruct,

    reset_val: u8,
    arm_boot_arch: u16 align(1),
    minor_version: u8,

    // 64-bit pointers - Available on ACPI 2.0+.
    x_fw_ctrl: u64 align(4),
    x_dsdt: u64 align(4),

    x_pm1a_event_blk: GenericAddrStruct,
    x_pm1b_event_blk: GenericAddrStruct,
    x_pm1a_ctrl_blk: GenericAddrStruct,
    x_pm1b_ctrl_blk: GenericAddrStruct,
    x_pm2_ctrl_blk: GenericAddrStruct,
    x_pm_timer_blk: GenericAddrStruct,
    x_gpe0_blk: GenericAddrStruct,
    x_gpe1_blk: GenericAddrStruct,

    sleep_ctrl_reg: GenericAddrStruct,
    sleep_stat_reg: GenericAddrStruct,

    hv_vendor_id: u64 align(4),

    comptime {
        std.debug.assert(@offsetOf(Fadt, "fw_ctrl") == 36);
        std.debug.assert(@offsetOf(Fadt, "acpi_enable") == 52);
        std.debug.assert(@offsetOf(Fadt, "pm_timer_blk") == 76);
        std.debug.assert(@offsetOf(Fadt, "iapc_boot_arch") == 109);
        std.debug.assert(@offsetOf(Fadt, "x_pm_timer_blk") == 208);

        std.debug.assert(@sizeOf(Fadt) == 276);
    }
};

const GenericAddrStruct = extern struct {
    addr_space: enum(u8) {
        system_mem = 0,
        system_io = 1,
        pci_cfg_space = 2,
        embedded_ctrl = 3,
        system_mgmt_bus = 4,
        system_cmos = 5,
        pci_dev_bar = 6,
        intl_plat_mgmt_infr = 7,
        gpio = 8,
        generic_serial_bus = 9,
        plat_comm_channel = 10,
        _
    },
    bit_width: u8,
    bit_offset: u8,
    access_size: enum(u8) {
        @"undefined" = 0,
        byte = 1,
        word = 2,
        dword = 3,
        qword = 4
    },

    address: u64 align(4),

    comptime {
        std.debug.assert(@sizeOf(GenericAddrStruct) == 12);
    }
};

const mmio_size = 512 * utils.kb_size;

var sdt: *Xsdt = undefined;
var fadt: *Fadt = undefined;

pub fn init() !void {
    const phys = boot.getArchData().acpi_ptr;

    _ = io.request("ACPI Tables", phys, mmio_size, .mmio) orelse return error.MmioBusy;
    errdefer io.release(phys, .mmio);

    sdt = @ptrFromInt(vm.getVirtLma(phys));

    if (!sdt.header.checkSum()) return error.XsdtChecksumFailed;

    const fadt_hdr = findEntry("FACP") orelse return error.FadtNotFound;
    if (!fadt_hdr.checkSum()) return error.FadtChecksumFailed;

    fadt = @alignCast(@ptrCast(fadt_hdr));
}

/// Used by `dev.init` after preinitialization.
/// Cannot be called in `acpi.init` because
/// `dev` subsystem is not yet initialized.
pub fn postInit() !void {
    timer.init();

    try enableSmm();
}

pub fn findEntry(signature: *const [4:0]u8) ?*SdtHeader {
    const entries = sdt.entries();

    for (entries) |ent| {
        const entry: *SdtHeader = vm.getVirtLma(ent);

        if (!std.mem.eql(u8, &entry.signature, signature)) continue;

        return entry;
    }

    return null;
}

pub inline fn getSdt() *const Xsdt {
    return sdt;
}

pub inline fn getFadt() *const Fadt {
    return fadt;
}

/// Enables ACPI if is not already enabled.
inline fn enableSmm() !void {
    if (fadt.smi_cmd_port == 0) return error.SmmNotSupported;
    io.outb(@truncate(fadt.smi_cmd_port), fadt.acpi_enable);
}

/// Disable ACPI, do nothing if not supported.
inline fn disableSmm() void {
    if (fadt.smi_cmd_port == 0) return;
    io.outb(@truncate(fadt.smi_cmd_port), fadt.acpi_disable);
}
