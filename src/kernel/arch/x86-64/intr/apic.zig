//! # APIC Driver

const std = @import("std");

const acpi = dev.acpi;
const arch = @import("../arch.zig");
const dev = @import("../../../dev.zig");
const intr = dev.intr;
const ioapic = @import("ioapic.zig");
const smp = @import("../../../smp.zig");
const lapic = @import("lapic.zig");
const pic = @import("pic.zig");

const c = @cImport(
    @cInclude("cpuid.h")
);

pub const Madt = extern struct {
    pub const Entry = extern struct {
        const Type = enum(u8) {
            proc_lapic = 0x0,
            ioapic = 0x1,
            ioapic_intr_src_overr = 0x2,
            ioapic_nmi_src = 0x3,
            ioapic_nmi = 0x4,
            lapic_addr_overr = 0x5,
            proc_lx2apic = 0x6
        };

        type: Type,
        length: u8
    };

    pub const ProcLapic = extern struct {
        header: Entry,
        acpi_proc_id: u8,
        apic_id: u8,
        flags: u32 align(1)
    };

    pub const Ioapic = extern struct {
        header: Entry,
        id: u8,
        reserved: u8,
        address: u32 align(1),
        gsi_base: u32 align(1),
    };

    pub const IntrSourceOverride = extern struct {
        header: Entry,
        bus: u8,
        irq: u8,
        gsi: u32 align(1),
        flags: u16 align(1), 
    };

    header: acpi.SdtHeader,
    lapic_base: u32,
    flags: u32,

    _entries: Entry,

    comptime {
        std.debug.assert(@alignOf(@This()) == @alignOf(u32));
    }

    pub fn findByType(self: *Madt, begin: ?*Entry, ent_type: Entry.Type) ?*Entry {
        var entry: *Entry = if (begin) |ent| blk: {
            break :blk @ptrFromInt(@intFromPtr(ent) + ent.length);
        } else &self._entries;

        const end_addr = @intFromPtr(&self._entries) + self.header.length;

        while (@intFromPtr(entry) < end_addr)
        : (entry = @ptrFromInt(@intFromPtr(entry) + entry.length)) {
            // Don`t trust hardware, avoid infinity loop
            if (entry.length == 0) break;

            if (entry.type == ent_type) return entry;
        }

        return null;
    }
};

pub const Interrupt = struct {
    pub const DeliveryMode = enum(u3) {
        fixed = 0,
        lowest_priority = 1,
        smi = 2,

        nmi = 4,
        init = 5,

        ext_init = 7
    };
    pub const DestinationMode = enum(u1) {
        physical = 0,
        logical = 1
    };
    pub const DeliveryStatus = enum(u1) {
        relaxed = 0,
        waiting = 1
    };
    pub const Polarity = enum(u1) {
        active_high = 0,
        active_low = 1
    };
    pub const TriggerMode = enum(u1) {
        edge = 0,
        level = 1
    };
};

const Msi = struct {
    pub const Address = packed struct {
        rsrvd: u2 = 0,

        dest_mode: Interrupt.DestinationMode,
        redir_hint: u1,

        rsrvd_1: u8 = 0,

        dest_id: u8,
        magic: u12 = 0xFEE,
    };

    pub const Data = packed struct {
        vector: u8,
        delv_mode: Interrupt.DeliveryMode,

        rsrvd: u3 = 0,

        pin_polarity: Interrupt.Polarity,
        trig_mode: Interrupt.TriggerMode,

        rsrvd_1: u16 = 0
    };
};

var madt: *Madt = undefined;

pub fn init() !void {
    if (!isAvail()) return error.NotAvailable;

    madt = @ptrCast(acpi.findEntry("APIC") orelse return error.NoMadt);

    if (!madt.header.checkSum()) return error.DamagedMadt;

    pic.disable();

    try lapic.init();
    try ioapic.init();
}

pub fn chip() intr.Chip {
    return .{
        .name = "APIC",
        .ops = .{
            .eoi = &eoi,
            .bindIrq = &bindIrq,
            .unbindIrq = &unbindIrq,
            .maskIrq = &maskIrq,
            .unmaskIrq = &unmaskIrq,
            //.configureMsi = &configureMsi,
        }
    };
}

pub inline fn getMadt() *Madt {
    return madt;
}

pub inline fn cpuIdxToApicId(cpu_idx: u16) u8 {
    return smp.getCpuData(cpu_idx).arch_specific.apic_id;
}

inline fn isAvail() bool {
    return (arch.cpuid(arch.cpuid_features, undefined, undefined, undefined).d & c.bit_APIC) != 0;
}

fn bindIrq(irq: *const intr.Irq) void {
    arch.intr.setupIsr(
        irq.vector,
        arch.intr.lowLevelIrqHandler(irq.pin),
        .kernel,
        arch.intr.intr_gate_flags,
    );

    const entry = ioapic.getRedirEntry(irq.pin);

    entry.set(.{
        .vector = @truncate(irq.vector.vec),
        .delv_mode = .fixed,
        .delv_status = .relaxed,
        .dest_mode = .physical,
        .dest = cpuIdxToApicId(irq.vector.cpu),
        .pin_polarity = .active_high,
        .trig_mode = switch(irq.trigger_mode) {
            .edge => .edge,
            .level => .level
        },
        .mask = 1,
    });
}

fn unbindIrq(irq: *const intr.Irq) void {
    _ = irq;
}

fn maskIrq(irq: *const intr.Irq) void {
    @setRuntimeSafety(false);
    ioapic.mask(irq.pin, true);
}

fn unmaskIrq(irq: *const intr.Irq) void {
    @setRuntimeSafety(false);
    ioapic.mask(irq.pin, false);
}

fn eoi() void {
    @setRuntimeSafety(false);
    lapic.set(.eoi, 0);
}

fn configureMsi(msi: *const intr.Msi) !intr.Msi.Message {
    const address = Msi.Address{
        .dest_id = msi.vector.cpu,
        .dest_mode = .physical,
        .redir_hint = 0
    };
    const data = Msi.Data{
        .vector = cpuIdxToApicId(msi.vector.cpu),
        .delv_mode = .fixed,
        .pin_polarity = .active_high,
        .trig_mode = .edge
    };

    return .{
        .address = @as(u32, @bitCast(address)),
        .data = @bitCast(data)
    };
}