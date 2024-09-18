const std = @import("std");

const boot = @import("../../boot.zig");
const io = @import("../io.zig");
const utils = @import("../../utils.zig");
const vm = @import("../../vm.zig");

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: u64 align(4),
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

    pub inline fn len(self: *const Xsdt) usize {
        return (self.header.length - @sizeOf(SdtHeader)) / @sizeOf(@TypeOf(self._entries));
    }

    pub inline fn entries(self: *Xsdt) [*]align(4) *SdtHeader {
        return @ptrCast(&self._entries);
    }
};

const mmio_size = 512 * utils.kb_size;

var sdt: *Xsdt = undefined;

pub fn init() !void {
    const phys = boot.getArchData().acpi_ptr;

    _ = io.request("ACPI Tables", phys, mmio_size, .mmio) orelse return error.MmioBusy;

    sdt = @ptrFromInt(phys);
    sdt = vm.getVirtLma(sdt);
}

pub fn findEntry(signature: *const [4:0]u8) ?*SdtHeader {
    for (sdt.entries()[0..sdt.len()]) |ent| {
        const entry: *SdtHeader = vm.getVirtLma(ent);

        if (!std.mem.eql(u8, &entry.signature, signature)) continue;

        return entry;
    }

    return null;
}
