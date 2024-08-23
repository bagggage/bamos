const std = @import("std");

const log = @import("../../log.zig");
const boot = @import("../../boot.zig");
const vm = @import("../../vm.zig");

pub const SDTHeader = extern struct {
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
};

pub const XSDT = extern struct {
    header: SDTHeader,
    _entries: *SDTHeader align(4),

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(SDTHeader) + @sizeOf(*SDTHeader));
    }

    pub inline fn len(self: *const XSDT) usize {
        return (self.header.length - @sizeOf(SDTHeader)) / @sizeOf(@TypeOf(self._entries));
    }

    pub inline fn entries(self: *XSDT) [*]align(4) *SDTHeader {
        return @ptrCast(&self._entries);
    }
};

var sdt: *XSDT = undefined;

pub fn init() void {
    sdt = @ptrFromInt(boot.getArchData().acpi_ptr);
    sdt = vm.getVirtDma(sdt);
}

pub fn findEntry(signature: *const [4:0]u8) ?*SDTHeader {
    for (sdt.entries()[0..sdt.len()]) |entry| {
        if (!std.mem.eql(u8, &entry.signature, signature)) continue;

        return entry;
    }

    return null;
}
