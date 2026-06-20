//! # Virtual memory managment implementation

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");

const lib = @import("../../lib.zig");
const regs = @import("regs.zig");
const vm = @import("../../vm.zig");

pub const page_size = 4096;

/// Linear Memory Access (LMA) region start address.
pub const lma_start = 0xFFFF800000000000;

pub const max_userspace_addr = 0x0000_7FFF_FFFF_FFFF;
pub const max_user_heap_addr = max_userspace_addr - lib.gb_size + 1;

const pages_per_2mb = (lib.mb_size * 2) / page_size;

pub const PageTable = struct {
    const Entry = packed struct {
        const Handle = struct {
            pte: *const Entry,
            pt_idx: u2
        };

        present: u1 = 0,
        writeable: u1 = 0,
        user_access: u1 = 0,
        write_through: u1 = 0,
        cache_disabled: u1 = 0,
        accessed: u1 = 0,
        dirty: u1 = 0,
        size: u1 = 0,
        global: u1 = 0,
        _ignored: u3 = 0,
        base: u40 = 0,
        _ignored2: u11 = 0,
        exec_disabled: u1 = 0,

        comptime {
            std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
            std.debug.assert(@bitSizeOf(@This()) == 64);
        }
    };

    const len = 512;

    entries: [len]Entry = .{ Entry{} } ** len,

    pub inline fn translateVirtToPhys(self: *const PageTable, virt: usize) ?usize {
        return bindings.getInstance().vm.page_table.translateVirtToPhys(self, virt);
    }

    pub inline fn accessPageAttributes(self: *const PageTable, virt: usize) vm.Page.Attributes {
        return bindings.getInstance().vm.page_table.accessPageAttributes(self, virt);
    }

    /// Maps a virtual memory range to a physical memory range.
    /// - `virt`: base virtual address to which physicall region must be mapped.
    /// - `phys`: region base physical address.
    /// - `pages`: number of pages to map.
    /// - `flags`: flags to specify (see `vm.MapFlags` structure).
    /// - `page_table`: target page table.
    pub inline fn map(self: *PageTable, virt: usize, phys: usize, pages: u32, flags: vm.MapFlags) vm.Error!void {
        return bindings.getInstance().vm.page_table.map(self, virt, phys, pages, flags);
    }

    pub inline fn unmap(self: *PageTable, virt: usize, pages: u32) void {
        return bindings.getInstance().vm.page_table.unmap(self, virt, pages);
    }

    pub inline fn format(writer: *std.Io.Writer, self: *const PageTable) std.Io.Writer.Error!void {
        return bindings.getInstance().vm.page_table.format(writer, self);
    }
};

pub inline fn lmaEnd() usize {
    return bindings.getInstance().vm.lmaEnd();
}

pub inline fn heapStart() usize {
    return bindings.getInstance().vm.heapStart();
}

pub inline fn isUserVirtAddr(virt: usize) bool {
    return (virt & 0xFFFF_8000_0000_0000) == 0;
}

pub inline fn getPageTable() *PageTable {
    const pt: *PageTable = @ptrFromInt(regs.getCr3() & ~@as(usize, 0xFFF));
    return vm.getVirtLma(pt);
}

pub inline fn setPageTable(pt: *const PageTable) void {
    const pt_phys = vm.getPhysLma(pt);
    const cr3 = pt_phys | (regs.getCr3() & @as(u64, 0xFFF));

    regs.setCr3(cr3);
}
