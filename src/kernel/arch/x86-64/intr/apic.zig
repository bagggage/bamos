//! # APIC Driver

const std = @import("std");

const acpi = dev.acpi;
const arch = @import("../arch.zig");
const dev = @import("../../../dev.zig");
const intr = dev.intr;
const ioapic = @import("ioapic.zig");
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

    pub const Ioapic = extern struct {
        header: Entry,
        id: u8,
        reserved: u8,
        address: u32,
        gsi_base: u32,
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
        }
    };
}

pub inline fn getMadt() *Madt {
    return madt;
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
        .dest = @truncate(irq.vector.cpu),
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
    ioapic.mask(irq.pin, true);
}

fn unmaskIrq(irq: *const intr.Irq) void {
    ioapic.mask(irq.pin, false);
}

fn eoi() void {
    lapic.set(.eoi, 0);
}