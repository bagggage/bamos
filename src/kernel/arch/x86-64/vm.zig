//! # Virtual memory managment implementation

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../../boot.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.@"x86-64.vm");
const regs = @import("regs.zig");
const vm = @import("../../vm.zig");

pub const page_size = 4096;

/// Linear Memory Access (LMA) region start address.
pub const lma_start = 0xFFFF800000000000;

pub const max_userspace_addr = 0x0000_8FFF_FFFF_FFFF;
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
        base: u28 = 0,
        _rsrvd: u12 = 0,
        _ignored2: u11 = 0,
        exec_disabled: u1 = 0,

        comptime {
            std.debug.assert(@sizeOf(@This()) == @sizeOf(u64));
            std.debug.assert(@bitSizeOf(@This()) == 64);
        }

        fn init(base: usize, flags: vm.MapFlags) @This() {
            var result: @This() = .{};

            result.present = 1;

            result.writeable = if (flags.write) 1 else 0;
            result.user_access = if (flags.user) 1 else 0;
            result.global = if (flags.global) 1 else 0;
            result.cache_disabled = if (flags.cache_disable) 1 else 0;
            result.size = if (flags.large) 1 else 0;
            result.exec_disabled = if (flags.exec) 0 else 1;

            result.base = @truncate(base / page_size);

            return result;
        }

        inline fn getBase(self: *const @This()) usize {
            return @as(usize, @intCast(self.base)) * vm.page_size;
        }

        inline fn nextPageTable(self: *const @This()) *PageTable {
            return @ptrFromInt(vm.getVirtLma(@as(usize, self.base) * page_size));
        }

        fn prioritizeFlags(self: *@This(), flags: vm.MapFlags) void {
            self.writeable |= @intFromBool(flags.write);
            self.user_access |= @intFromBool(flags.user);
            self.cache_disabled &= @intFromBool(flags.cache_disable);
            self.exec_disabled &= @intFromBool(flags.exec == false);
        }

        fn remapLarge(pte: *PageTable.Entry, is_gb_page: bool) vm.Error!void {
            var template_pte = pte.*;
            template_pte.size = if (is_gb_page) 1 else 0;

            const pt = PageTable.new() orelse return vm.Error.NoMemory;

            pte.base = @truncate(@intFromPtr(vm.getPhysLma(pt)) / page_size);
            pte.size = 0;
            pte.global = 0;

            const pages_step: u16 = if (is_gb_page) pages_per_2mb else 1;

            for (0..PageTable.len) |i| {
                pt.entries[i] = template_pte;
                template_pte.base += pages_step;
            }
        }

        fn formatHelper(self: *const Entry, writer: *std.Io.Writer, region_len: u16, level: u3) void {
            const pte_idx = (@intFromPtr(self) & 0xFFF) / @sizeOf(Entry);
            const prefix = fmt.prefixies[level];

            if (region_len > 1) {
                writer.print("{s}P{} [{}-{}]: 0x{x}->0x{x} {} {s}\n", .{
                    prefix, 4 - level, pte_idx, pte_idx + region_len - 1,
                    self.getBase(), self.getBase() + ((region_len - 1) * fmt.size_steps[level]),
                    fmt.size_units[level] * region_len, fmt.size_strs[level]
                });
            } else if (level != 3 and self.size == 0) {
                writer.print("{s}P{} [{}]: 0x{x}->0x{x}\n", .{
                    prefix, 4 - level, pte_idx,
                    vm.getPhysLma(@intFromPtr(self)), self.getBase()
                });
            } else {
                writer.print("{s}P{} [{}] -> 0x{x} {} {s}\n", .{
                    prefix, 4 - level, pte_idx, self.getBase(),
                    fmt.size_units[level], fmt.size_strs[level]
                });
            }
        }
    };

    const fmt = struct {
        const prefixies = [_][]const u8{ "", "|---", "|---|---", "|---|---|---" };
        const size_strs = [_][]const u8{ "", "GB", "MB", "KB" };
        const size_steps = [_]usize{ 0, lib.gb_size, lib.mb_size * 2, lib.kb_size * 4 };
        const size_units = [_]u8{ 0, 1, 2, 4 };
    };

    const len = 512;
    const oma_pool_pages = pages_per_2mb;

    var oma: vm.ObjectAllocator = undefined;

    entries: [len]Entry = .{ Entry{} } ** len,

    pub fn new() ?*PageTable {
        const pt = oma.alloc(PageTable) orelse return null;
        pt.* = .{};

        return pt;
    }

    pub inline fn free(self: *PageTable) void {
        oma.free(self);
    }

    pub fn translateVirtToPhys(self: *const PageTable, virt: usize) ?usize {
        const handle = self.translateVirtToPte(virt) orelse return null;
        return handle.pte.getBase() | getInpageOffset(3 - handle.pt_idx, virt);
    }

    pub fn accessPageAttributes(self: *const PageTable, virt: usize) vm.Page.Attributes {
        const pte = @constCast((self.translateVirtToPte(virt) orelse return .{}).pte);
        defer { pte.accessed = 0; pte.dirty = 0; }
        return .{
            .mapped = true,
            .writeable = pte.writeable != 0,
            .accessed = pte.accessed != 0,
            .dirty = pte.dirty != 0
        };
    }

    /// Maps a virtual memory range to a physical memory range.
    /// 
    /// - `virt`: base virtual address to which physicall region must be mapped.
    /// - `phys`: region base physical address.
    /// - `pages`: number of pages to map.
    /// - `flags`: flags to specify (see `vm.MapFlags` structure).
    /// - `page_table`: target page table.
    pub fn map(self: *PageTable, virt: usize, phys: usize, pages: u32, flags: vm.MapFlags) vm.Error!void {
        var pte_flags = correctMapFlags(flags, virt, phys, pages);
        var template_pte: Entry = .init(phys, pte_flags);

        var pt_stack: [4]?[*]Entry = .{null} ** 4;

        var pte_idx = getPxeIdx(3, virt);
        var pte: [*]Entry = self.entries[pte_idx..].ptr;

        var max_pt: u8 = 3;
        if (pte_flags.large) {
            max_pt = if (pages >= (lib.gb_size / page_size) and
                (virt % lib.gb_size) == 0 and
                (phys % lib.gb_size) == 0) 1 else 2;
        }

        var mapped_pages: u28 = 0;
        var pt_idx: u32 = 0;

        while (pt_idx < 4) {
            if (pt_idx < max_pt) {
                // Just lookup next enty in next page table
                if (pte[0].present == 0) {
                    // Allocate new page table if not present
                    const new_pt = PageTable.new() orelse return vm.Error.NoMemory;

                    pte[0] = template_pte;
                    pte[0].size = 0;
                    pte[0].global = 0;
                    pte[0].base = @truncate(@intFromPtr(vm.getPhysLma(new_pt)) / page_size);
                } else if (pte[0].size == 1) {
                    // Remap large page
                    try pte[0].remapLarge(pt_idx == 1);
                    pte[0].prioritizeFlags(pte_flags);
                } else {
                    pte[0].prioritizeFlags(pte_flags);
                }

                // Push next to the current pte on the stack
                if (pte_idx == 511) {
                    pt_stack[pt_idx] = null;
                } else {
                    pt_stack[pt_idx] = pte + 1;
                }

                // Go to the next pte in the next page table
                pte_idx = if (mapped_pages == 0) getPxeIdx(@truncate(2 - pt_idx), virt) else 0;
                pte = pte[0].nextPageTable().entries[pte_idx..].ptr;
                pt_idx += 1;
            } else {
                // Begin mapping
                var entries_to_map = pages - mapped_pages;
                var pages_step: u28 = 1;

                if (pte_flags.large) {
                    switch (max_pt) {
                        1 => {
                            pages_step = lib.gb_size / page_size;
                            entries_to_map /= pages_step;
                        },
                        2 => {
                            pages_step = pages_per_2mb;
                            entries_to_map /= pages_step;
                        },
                        else => unreachable,
                    }
                }

                while (entries_to_map > 0 and pte_idx < PageTable.len) : ({
                    pte_idx += 1;
                    entries_to_map -= 1;
                }) {
                    pte[0] = template_pte;
                    pte[0].base += mapped_pages;

                    mapped_pages += pages_step;
                    pte += 1;
                }

                if (entries_to_map == 0) {
                    std.debug.assert(mapped_pages <= pages);

                    if (mapped_pages == pages) return;

                    std.debug.assert(pte_flags.large);

                    if (max_pt == 2) {
                        pte_flags.large = false;
                        template_pte.size = 0;
                    }

                    max_pt += 1;
                }

                std.debug.assert(pte_idx == PageTable.len);

                while (pt_stack[pt_idx - 1] == null) {
                    pt_idx -= 1;
                }

                pt_idx -= 1;
                pte = pt_stack[pt_idx].?;
                pte_idx = @truncate((@intFromPtr(pte) & 0xFFF) / @sizeOf(Entry));

                std.debug.assert(pte_idx > 0);
            }
        }

        unreachable;
    }

    pub fn unmap(self: *PageTable, virt: usize, pages: u32) void {
        var pt_stack: [4]?[*]Entry = .{null} ** 4;

        var pte_idx = getPxeIdx(3, virt);
        var pte: [*]Entry = self.entries[pte_idx..].ptr;

        var mapped_pages: u28 = 0;
        var pt_idx: u32 = 0;

        while (pt_idx < 4) {
            if (pt_idx < 3) {
                // Just lookup next entry in next page table
                if (pte[0].present == 0) {
                    // Page table not present, nothing to unmap
                    return;
                } else if (pte[0].size != 0) {
                    // Remap large page
                    pte[0].remapLarge(pt_idx == 1) catch {
                        // TODO: fix it!
                        return;
                    };
                }

                // Push next to the current pte on the stack
                if (pte_idx == 511) {
                    pt_stack[pt_idx] = null;
                } else {
                    pt_stack[pt_idx] = pte + 1;
                }

                // Go to the next pte in the next page table
                pte_idx = if (mapped_pages == 0) getPxeIdx(@truncate(2 - pt_idx), virt) else 0;
                pte = pte[0].nextPageTable().entries[pte_idx..].ptr;
                pt_idx += 1;
            } else {
                // Begin unmapping
                var entries_to_unmap = pages - mapped_pages;
                var pages_step: u28 = 1;

                // Check if this is a large page
                if (pte[0].size == 1) {
                    // Determine if this is a 1GB or 2MB page
                    const is_1gb = (pt_idx == 1);
                    pages_step = if (is_1gb)
                        (lib.gb_size / page_size)
                    else
                        pages_per_2mb;

                    entries_to_unmap = 1; // Large page covers all remaining entries
                }

                while (entries_to_unmap > 0 and pte_idx < PageTable.len) : ({
                    pte_idx += 1;
                    entries_to_unmap -= 1;
                }) {
                    pte[0].present = 0;
                    mapped_pages += pages_step;
                    pte += 1;
                }

                if (entries_to_unmap == 0) {
                    if (mapped_pages == pages) return;
                }

                std.debug.assert(pte_idx == PageTable.len);

                // Go back up the stack
                while (pt_idx > 0 and pt_stack[pt_idx - 1] == null) {
                    pt_idx -= 1;
                }

                if (pt_idx == 0) return;

                pt_idx -= 1;
                pte = pt_stack[pt_idx].?;
                pte_idx = @truncate((@intFromPtr(pte) & 0xFFF) / @sizeOf(Entry));

                std.debug.assert(pte_idx > 0);
            }
        }
    }

    pub inline fn format(writer: *std.Io.Writer, self: *const PageTable) void {
        self.formatLevel(writer, 0);
    }

    fn formatLevel(self: *const PageTable, writer: *std.Io.Writer, level: u2) void {
        var pte_idx: u16 = 0;

        while (pte_idx < PageTable.len) : (pte_idx += 1) {
            const pte = &self.entries[pte_idx];
            if (pte.present == 0) continue;

            if (pte.size == 1 or level == 3) {
                const max_len = PageTable.len - pte_idx;
                var region: u16 = 1;
                for (1..max_len) |i| {
                    const idx = pte_idx + i;

                    if (self.entries[idx].base != pte.base + ((fmt.size_steps[level] / page_size) * i) or
                        self.entries[idx].present == 0 or i == max_len - 1)
                    {
                        region = @truncate(i);
                        break;
                    }
                }

                pte.formatHelper(writer, region, level);
                pte_idx += region - 1;
            } else {
                pte.formatHelper(writer, 1, level);
                pte.nextPageTable().formatLevel(writer, level + 1);
            }
        }
    }

    fn correctMapFlags(flags: vm.MapFlags, virt: usize, phys: usize, pages: u32) vm.MapFlags {
        var result = flags;
        if (flags.large) {
            if (pages < pages_per_2mb or
                (virt % (2 * lib.mb_size) != 0 or
                    phys % (2 * lib.mb_size) != 0)) result.large = false;
        }

        return result;
    }

    fn translateVirtToPte(self: *const PageTable, virt: usize) ?Entry.Handle {
        var pte = &self.entries[getPxeIdx(3, virt)];
        for (0..4) |pt_idx| {
            if (pte.present == 0) break;
            if (pte.size == 1 or pt_idx == 3) return .{ .pte = pte, .pt_idx = @truncate(pt_idx) };

            pte = &pte.nextPageTable().entries[getPxeIdx(@truncate(2 - pt_idx), virt)];
        }

        return null;
    }

    inline fn getPxeIdx(pt_idx: u8, virt: usize) u16 {
        return @truncate((virt >> @truncate((pt_idx * 9) + 12)) & 0x1FF);
    }

    inline fn getInpageOffset(pt_idx: u8, virt: usize) u12 {
        return @truncate(virt & ~(~@as(usize, 0xFFF) << @truncate(pt_idx * 9)));
    }
};

var lma_end: usize = 0;
var heap_start: usize = 0;

pub fn preinit() void {
    earlyMapLma();
    boot.switchToLma();
}

pub fn init() vm.Error!void {
    const rank = std.math.log2(PageTable.oma_pool_pages);
    const oma_pool = vm.PageAllocator.alloc(rank) orelse return vm.Error.NoMemory;

    PageTable.oma = try .initRaw(@sizeOf(PageTable), oma_pool, PageTable.oma_pool_pages);
}

pub inline fn lmaEnd() usize {
    return lma_end;
}

pub inline fn heapStart() usize {
    return heap_start;
}

pub inline fn isUserVirtAddr(virt: usize) bool {
    return (virt & 0xFFFF_0000_0000_0000) == 0;
}

pub inline fn getPageTable() *PageTable {
    const pt: *PageTable = @ptrFromInt(regs.getCr3() & ~@as(usize, 0xFFF));
    return vm.getVirtLma(pt);
}

pub inline fn setPageTable(pt: *const PageTable) void {
    const pt_phys = vm.getPhysLma(@intFromPtr(pt));
    const cr3 = pt_phys | (regs.getCr3() & @as(u64, 0xFFF));

    regs.setCr3(cr3);
}

pub fn copyKernelMappings(source: *const PageTable, dest: *PageTable) void {
    const lma_pte_idx = comptime PageTable.getPxeIdx(3, lma_start);
    const heap_pte_idx = PageTable.getPxeIdx(3, heap_start);
    const kernel_pte_idx = PageTable.getPxeIdx(3, @intFromPtr(&init));

    dest.entries[lma_pte_idx] = source.entries[lma_pte_idx];
    dest.entries[heap_pte_idx] = source.entries[heap_pte_idx];
    dest.entries[kernel_pte_idx] = source.entries[kernel_pte_idx];
}

fn earlyMapLma() void {
    const lma_size = calcLmaSize();

    lma_end = lma_start + lma_size;
    heap_start = lma_end + lib.gb_size;

    const pt = vm.getPhysLma(getPageTable());
    const p4_idx = comptime PageTable.getPxeIdx(3, lma_start);

    const pt3: *PageTable = @ptrFromInt(boot.alloc(1).?);
    @memset(@as(*[PageTable.len]u64, @ptrCast(pt3))[0..PageTable.len], 0);

    const pte: *PageTable.Entry = &pt.entries[p4_idx];
    pte.* = .init(@intFromPtr(pt3), vm.MapFlags{ .write = true });

    var template_pte: PageTable.Entry = .init(0, vm.MapFlags{ .write = true, .global = true, .large = true });
    const len = lma_size / lib.gb_size;
    const gb_pages = lib.gb_size / vm.page_size;

    for (pt3.entries[0..len]) |*entry| {
        entry.* = template_pte;
        template_pte.base += gb_pages;
    }
}

fn calcLmaSize() usize {
    // TODO: implement this to ensure that
    // all physical memory is accessible via LMA.

    // Currently just return 256 GB.
    return 256 * lib.gb_size;
}
