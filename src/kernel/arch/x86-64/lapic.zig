const std = @import("std");

const acpi = @import("../../dev/stds/acpi.zig");
const boot = @import("../../boot.zig");
const log = @import("../../log.zig");
const regs = @import("regs.zig");
const vm = @import("../../vm.zig");

pub const ID_REG = 0x20;
pub const APIC_ENABLED = 0x800;

const MADT = extern struct {
    const Entry = extern struct { type: u8, length: u8 };

    header: acpi.SDTHeader,
    lapic_base: u32,
    flags: u32,
    _entries: Entry,

    comptime {
        std.debug.assert(@alignOf(@This()) == @alignOf(u32));
    }

    pub inline fn entries(self: *MADT) [*]Entry {
        return @ptrCast(&self._entries);
    }
};

var madt: *MADT = undefined;
var base: [*]u32 = undefined;

pub inline fn init() void {
    if (acpi.findEntry("APIC")) |entry| {
        madt = @ptrCast(entry);
    } else {
        @panic("Can't found LAPIC MADT entry within ACPI");
    }

    base = @ptrFromInt(@as(usize, madt.lapic_base));
    base = vm.getVirtDma(base);

    // Set enabled APIC in MSR
    regs.setMsr(regs.MSR_APIC_BASE, regs.getMsr(regs.MSR_APIC_BASE) | APIC_ENABLED);
}

pub inline fn read(reg_offset: u32) u32 {
    return @as(*const u32, @ptrFromInt(@intFromPtr(base) + reg_offset)).*;
}

pub inline fn write(reg_offset: u32, value: u32) void {
    base[reg_offset / @sizeOf(u32)] = value;
}

pub inline fn getId() u32 {
    return read(ID_REG) >> 24;
}
