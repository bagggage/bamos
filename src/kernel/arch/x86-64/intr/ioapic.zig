//! # IOAPIC

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const acpi = dev.acpi;
const apic = @import("apic.zig");
const boot = @import("../../../boot.zig");
const dev = @import("../../../dev.zig");
const io = dev.io;
const intr = @import("../intr.zig");
const log = @import("../../../log.zig");
const vm = @import("../../../vm.zig");

const Interrupt = apic.Interrupt;

const Ioapic = struct {
    const InternalRegs = dev.regs.Group(
        io.MmioMechanism("IOAPIC", .dword), null, 0x1000, &.{
            dev.regs.reg("IOREGSEL", 0x0, null, .write),
            dev.regs.reg("IOREGWIN", 0x10, null, .rw)
    });

    pub const Regs = enum(u8) {
        id = 0x0,
        ver = 0x1,
        arb = 0x2,

        const redir_tbl_base = 0x10;
    };

    id: u8,
    version: u8,
    max_redirs: u8,

    madt_ent: *Madt.Ioapic,
    internal_regs: InternalRegs,

    pub fn init(madt_ent: *Madt.Ioapic) !Ioapic {
        var result: Ioapic = .{
            .id = madt_ent.id,

            .version = undefined,
            .max_redirs = undefined,

            .madt_ent = madt_ent,
            .internal_regs = try InternalRegs.initBase(madt_ent.address),
        };

        const ver = result.get(.ver);

        result.version = @truncate(ver);
        result.max_redirs = @truncate((ver >> 16) + 1);

        return result;
    }

    pub inline fn read(self: *const Ioapic, offset: u8) u32 {
        self.internal_regs.write(.IOREGSEL, offset);
        return self.internal_regs.read(.IOREGWIN);
    }

    pub inline fn write(self: *Ioapic, offset: u8, value: u32) void {
        self.internal_regs.write(.IOREGSEL, offset);
        self.internal_regs.write(.IOREGWIN, value);
    }

    pub inline fn get(self: *const Ioapic, reg: Regs) u32 {
        return self.read(@intFromEnum(reg));
    }

    pub inline fn set(self: *Ioapic, reg: Regs, value: u32) void {
        self.write(@intFromEnum(reg), value);
    }
};

const RedirEntry = struct {
    const Struct = packed struct {
        vector: u8,
        delv_mode: Interrupt.DeliveryMode,
        dest_mode: Interrupt.DestinationMode,
        delv_status: Interrupt.DeliveryStatus,
        pin_polarity: Interrupt.Polarity,
        remote_irr: u1 = 0,
        trig_mode: Interrupt.TriggerMode,
        mask: u1,

        _: u39 = 0,

        dest: u8,

        comptime {
            std.debug.assert(@sizeOf(Struct) == @sizeOf(u64));
            std.debug.assert(@bitOffsetOf(Struct, "mask") == 16);
        }

        pub fn format(self: *const Struct, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("vec: {}, delv_mode: {s}, dest_mode: {s}, delv_status: {s}, polarity: {s}, trig_mode: {s}, mask: {}", .{
                self.vector, @tagName(self.delv_mode), @tagName(self.dest_mode), @tagName(self.delv_status),
                @tagName(self.pin_polarity), @tagName(self.trig_mode), self.mask
            });
        }
    };

    io: *Ioapic,
    offset: u8,

    pub inline fn get(self: *const RedirEntry) Struct {
        return @bitCast(
            @as(u64, self.io.read(self.offset)) |
            @as(u64, self.io.read(self.offset + 1)) >> 32
        );
    }

    pub inline fn set(self: *const RedirEntry, value: Struct) void {
        const raw_val: u64 = @bitCast(value);

        self.io.write(self.offset, @truncate(raw_val));
        self.io.write(self.offset + 1, @truncate(raw_val >> 32));
    }

    pub inline fn mask(self: *const RedirEntry, disable: bool) void {
        const bitmask = @as(u32, 1) << @bitOffsetOf(Struct, "mask");
        const half = self.io.read(self.offset);

        self.io.write(self.offset, half & if (disable) bitmask else ~bitmask);
    }
};

const Madt = apic.Madt;
const IoapicArray = std.BoundedArray(Ioapic, max_ioapics);

const max_ioapics = 4;
const max_overrides = 16;

var ioapics = IoapicArray.init(0) catch unreachable;
var max_irqs: u16 = 0;
var irq_overrides: [max_overrides]u8 = blk: {
    var temp: [max_overrides]u8 = undefined;
    for (0..max_overrides) |i| { temp[i] = @truncate(i); }
    break :blk temp;
};

pub fn init() !void {
    const madt = apic.getMadt();

    var entry: ?*Madt.Entry = null;

    while (madt.findByType(entry, .ioapic)) |ent| : (entry = ent) {
        const ioapic_ent: *align(2) Madt.Ioapic = @alignCast(@ptrCast(ent));
        const ioapic = Ioapic.init(ioapic_ent) catch |err| {
            log.err("Failed to initialize IOAPIC-{}: {}", .{ioapic_ent.id,err});
            continue;
        };

        ioapics.append(ioapic) catch unreachable;
        max_irqs += ioapic.max_redirs;

        log.debug("IOAPIC-{}: max redirections: {}, gsi base: {}", .{
            ioapic.madt_ent.id, ioapic.max_redirs, ioapic_ent.gsi_base
        });

        if (ioapics.len == max_ioapics) {
            log.warn("Reached IOAPIC limit: {}; Others ignored", .{max_ioapics});
            break;
        }
    }

    entry = null;

    while (madt.findByType(entry, .ioapic_intr_src_overr)) |ent| : (entry = ent) {
        const override: *Madt.IntrSourceOverride = @ptrCast(ent);

        irq_overrides[override.irq] = @truncate(override.gsi);

        log.debug("IRQ override: {}->{}", .{override.irq, override.gsi});
    }
}

pub inline fn getMaxIrqs() u16 {
    return max_irqs;
}

pub fn getRedirEntry(irq: u8) RedirEntry {
    std.debug.assert(irq < max_irqs);

    const gsi = if (irq < max_overrides) irqToGsi(irq) else irq;

    for (ioapics.slice()) |*ioapic| {
        const begin = ioapic.madt_ent.gsi_base;
        const end = begin + ioapic.max_redirs;

        if (gsi < begin or gsi >= end) continue;

        return .{
            .io = ioapic,
            .offset = @truncate((gsi - begin) * 2 + Ioapic.Regs.redir_tbl_base)
        };
    }

    unreachable;
}

pub inline fn mask(irq: u8, disable: bool) void {
    getRedirEntry(irq).mask(disable);
}

pub inline fn irqToGsi(irq: u8) u8 {
    return irq_overrides[irq];
}