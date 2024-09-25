//! # IOAPIC

const std = @import("std");

const acpi = dev.acpi;
const apic = @import("apic.zig");
const boot = @import("../../../boot.zig");
const dev = @import("../../../dev.zig");
const io = dev.io;
const intr = @import("../intr.zig");
const log = @import("../../../log.zig");
const vm = @import("../../../vm.zig");

const Ioapic = struct {
    const InternalRegs = dev.regs.RegsGroup(
        "IOAPIC", .mmio, .dword, &.{
            dev.regs.reg("IOREGSEL", 0x0),
            dev.regs.reg("IOREGWIN", 0x10)
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
            .internal_regs = try InternalRegs.init(madt_ent.address),
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
        const DeliveryMode = enum(u3) {
            fixed = 0,
            lowest_priority = 1,
            smi = 2,

            nmi = 4,
            init = 5,

            ext_init = 7
        };
        const DestinationMode = enum(u1) {
            physical = 0,
            logical = 1
        };
        const DeliveryStatus = enum(u1) {
            relaxed = 0,
            waiting = 1
        };
        const Polarity = enum(u1) {
            active_high = 0,
            active_low = 1
        };
        const TriggerMode = enum(u1) {
            edge = 0,
            level = 1
        };

        vector: u8,
        delv_mode: DeliveryMode,
        dest_mode: DestinationMode,
        delv_status: DeliveryStatus,
        pin_polarity: Polarity,
        remote_irr: u1,
        trig_mode: TriggerMode,
        mask: u1,

        _: u39,

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
        self.io.write(self.offset + 1, @truncate(raw_val << 32));
    }

    pub inline fn mask(self: *const RedirEntry, disable: bool) void {
        const bitmask = @as(u32, 1) << @bitOffsetOf(Struct, "mask");
        const half = self.io.read(self.offset);

        self.io.write(self.offset, half & if (disable) bitmask else ~bitmask);
    }
};

const Madt = apic.Madt;
const IoapicArray = std.BoundedArray(Ioapic, max_ioapics);

const irqs_per_ioapic = 24;
const max_ioapics = 4;

var ioapics = IoapicArray.init(0) catch unreachable;
var max_irqs: u16 = 0;

pub fn init() !void {
    const madt = apic.getMadt();

    var entry: ?*Madt.Entry = null;

    while (madt.findByType(entry, .ioapic)) |ent| : (entry = ent) {
        const ioapic_ent: *Madt.Ioapic = @alignCast(@ptrCast(ent));
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
}

pub inline fn getMaxIrqs() u16 {
    return max_irqs;
}

pub fn getRedirEntry(irq: u8) RedirEntry {
    std.debug.assert(irq < max_irqs);

    const io_idx = irq / irqs_per_ioapic;
    const io_irq_idx = irq % irqs_per_ioapic;

    return .{
        .io = &ioapics.buffer[io_idx],
        .offset = Ioapic.Regs.redir_tbl_base + (io_irq_idx * 2)
    };
}

pub inline fn mask(irq: u8, disable: bool) void {
    getRedirEntry(irq).mask(disable);
}