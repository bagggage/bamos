//! # Virtual memory managment implementation

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../../boot.zig");
const log = std.log.scoped(.@"x86-64.vm");
const regs = @import("regs.zig");
const vm = @import("../../vm.zig");
const utils = @import("../../utils.zig");

pub const page_size = 4096;
pub const page_table_size = 512;

/// Linear Memory Access (LMA) region start address.
pub const lma_start = 0xFFFF800000000000;
/// Linear Memory Access (LMA) region size address.
pub const lma_size = utils.gb_size * 256;
/// Linear Memory Access (LMA) region end address.
pub const lma_end = lma_start + lma_size;

pub const heap_start = lma_end + utils.gb_size;

pub const max_user_head_addr = 0x0000_8FFF_FFFF_FFFF - utils.gb_size;
pub const max_userspace_addr = 0x0000_8FFF_FFFF_FFFF;

const pt_pool_pages = 512;
const pages_per_2mb = (utils.mb_size * 2) / page_size;

const PageTableEntry = packed struct {
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

    pub fn init(base: usize, flags: vm.MapFlags) @This() {
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

    pub inline fn getBase(self: *const @This()) usize {
        return @as(usize, @intCast(self.base)) * vm.page_size;
    }

    pub inline fn nextPt(self: *const @This()) *PageTable {
        return @ptrFromInt(vm.getVirtLma(@as(usize, self.base) * page_size));
    }

    pub fn prioritizeFlags(self: *@This(), flags: vm.MapFlags) void {
        self.writeable |= @intFromBool(flags.write);
        self.user_access |= @intFromBool(flags.user);
        self.cache_disabled &= @intFromBool(flags.cache_disable);
        self.exec_disabled &= @intFromBool(flags.exec == false);
    }
};

pub const PageTable = [page_table_size]PageTableEntry;

var pt_oma: vm.ObjectAllocator = undefined;

pub fn preinit() void {
    earlyMmapDma();
    boot.switchToLma();
}

pub fn init() vm.Error!void {
    const rank = std.math.log2(pt_pool_pages);
    const oma_pool = vm.PageAllocator.alloc(rank) orelse return vm.Error.NoMemory;

    pt_oma = try vm.ObjectAllocator.initRaw(@sizeOf(PageTable), oma_pool, pt_pool_pages);
}

pub inline fn allocPt() ?*PageTable {
    const pt = pt_oma.alloc(PageTable) orelse return null;
    @memset(pt, PageTableEntry{});

    return pt;
}

pub inline fn freePt(pt: *PageTable) void {
    pt_oma.free(pt);
}

pub inline fn getPt() *PageTable {
    const pt: *PageTable = @ptrFromInt(regs.getCr3() & (~@as(usize, 0xFFF)));
    return vm.getVirtLma(pt);
}

pub inline fn setPt(pt: *const PageTable) void {
    const pt_phys = vm.getPhysLma(@intFromPtr(pt));
    const cr3 = pt_phys | (regs.getCr3() & @as(u64, 0xFFF));

    regs.setCr3(cr3);
}

pub inline fn clonePt(src_pt: *const PageTable, dest_pt: *PageTable) void {
    const dma_pte_idx = comptime getPxeIdx(3, lma_start);
    const heap_pte_idx = comptime getPxeIdx(3, heap_start);
    const kernel_pte_idx = getPxeIdx(3, @intFromPtr(&init));

    dest_pt[dma_pte_idx] = src_pt[dma_pte_idx];
    dest_pt[heap_pte_idx] = src_pt[heap_pte_idx];
    dest_pt[kernel_pte_idx] = src_pt[kernel_pte_idx];
}

pub inline fn logPt(pt: *const PageTable) void {
    logPtRec(pt, 0);
}

const LogPt = struct {
    const prefixies = [_][]const u8{ "", "|---", "|---|---", "|---|---|---" };
    const size_strs = [_][]const u8{ "", "GB", "MB", "KB" };
    const size_steps = [_]usize{ 0, utils.gb_size, utils.mb_size * 2, utils.kb_size * 4 };
    const size_units = [_]u8{ 0, 1, 2, 4 };
};

fn logPtRec(pt: *const PageTable, level: u2) void {
    var pte_idx: u16 = 0;

    while (pte_idx < page_table_size) : (pte_idx += 1) {
        const pte = &pt[pte_idx];

        if (pte.present == 0) continue;

        if (pte.size == 1 or level == 3) {
            const max_len = page_table_size - pte_idx;
            var len: u16 = 1;

            for (1..max_len) |i| {
                const idx = pte_idx + i;

                if (pt[idx].base != pte.base + ((LogPt.size_steps[level] / page_size) * i) or
                    pt[idx].present == 0 or i == max_len - 1)
                {
                    len = @truncate(i);
                    break;
                }
            }

            logPte(pte, len, level);
            pte_idx += len - 1;
        } else {
            logPte(pte, 1, level);
            logPtRec(pte.nextPt(), level + 1);
        }
    }
}

fn logPte(pte: *const PageTableEntry, len: u16, level: u3) void {
    const pte_idx = (@intFromPtr(pte) & 0xFFF) / @sizeOf(PageTableEntry);
    const prefix = LogPt.prefixies[level];

    if (len > 1) {
        log.warn("{s}P{} [{}-{}]: 0x{x}->0x{x} {} {s}", .{
            prefix, 4 - level, pte_idx, pte_idx + len - 1,
            pte.getBase(), pte.getBase() + ((len - 1) * LogPt.size_steps[level]),
            LogPt.size_units[level] * len, LogPt.size_strs[level]
        });
    } else if (level != 3 and pte.size == 0) {
        log.warn("{s}P{} [{}]: 0x{x}->0x{x}", .{
            prefix, 4 - level, pte_idx,
            vm.getPhysLma(@intFromPtr(pte)), pte.getBase()
        });
    } else {
        log.warn("{s}P{} [{}] -> 0x{x} {} {s}", .{
            prefix, 4 - level, pte_idx, pte.getBase(),
            LogPt.size_units[level], LogPt.size_strs[level]
        });
    }
}

fn earlyMmapDma() void {
    const pt = vm.getPhysLma(getPt());
    const p4_idx = getPxeIdx(3, lma_start);

    const pt3: *PageTable = @ptrFromInt(boot.alloc(1).?);
    @memset(@as(*[page_table_size]u64, @ptrCast(pt3))[0..page_table_size], 0);

    const pte: *PageTableEntry = &pt[p4_idx];
    pte.* = PageTableEntry.init(@intFromPtr(pt3), vm.MapFlags{ .write = true });

    var template_pte = PageTableEntry.init(
        0,
        vm.MapFlags{ .write = true, .global = true, .large = true }
    );
    const len = lma_size / utils.gb_size;
    const gb_pages = utils.gb_size / vm.page_size;

    for (pt3[0..len]) |*entry| {
        entry.* = template_pte;
        template_pte.base += gb_pages;
    }
}

inline fn getPxeIdx(pt_idx: u8, virt: usize) u16 {
    return @truncate((virt >> @truncate((pt_idx * 9) + 12)) & 0x1FF);
}

inline fn getInpageOffset(pt_idx: u8, virt: usize) u12 {
    return @truncate(virt & ~(~@as(usize, 0xFFF) << @truncate(pt_idx * 9)));
}

pub fn getPhys(virt: usize, pt: *const PageTable) ?usize {
    var pte = &pt[getPxeIdx(3, virt)];

    for (0..4) |pt_idx| {
        if (pte.present == 0) break;

        if (pte.size == 1 or pt_idx == 3) {
            return pte.getBase() | getInpageOffset(@truncate(3 - pt_idx), virt);
        }

        pte = &pte.nextPt()[getPxeIdx(@truncate(2 - pt_idx), virt)];
    }

    return null;
}

pub fn mmap(virt: usize, phys: usize, pages: u32, flags: vm.MapFlags, page_table: *PageTable) vm.Error!void {
    var pte_flags = correctMmapFlags(flags, virt, phys, pages);
    var template_pte = PageTableEntry.init(phys, pte_flags);

    var pt_stack: [4]?[*]PageTableEntry = .{null} ** 4;

    var pte_idx = getPxeIdx(3, virt);
    var pte: [*]PageTableEntry = page_table[pte_idx..].ptr;

    var max_pt: u8 = 3;
    if (pte_flags.large) {
        max_pt = if (pages >= (utils.gb_size / page_size) and
            (virt % utils.gb_size) == 0 and
            (phys % utils.gb_size) == 0) 1 else 2;
    }

    var mapped_pages: u28 = 0;
    var pt_idx: u32 = 0;

    while (pt_idx < 4) {
        if (pt_idx < max_pt) {
            // Just lookup next enty in next page table
            if (pte[0].present == 0) {
                // Allocate new page table if not present
                const new_pt = allocPt() orelse return vm.Error.NoMemory;

                pte[0] = template_pte;
                pte[0].size = 0;
                pte[0].global = 0;
                pte[0].base = @truncate(@intFromPtr(vm.getPhysLma(new_pt)) / page_size);
            } else if (pte[0].size == 1) {
                // Remap large page
                try remapLarge(&pte[0], pt_idx == 1);
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
            pte = pte[0].nextPt()[pte_idx..].ptr;
            pt_idx += 1;
        } else {
            // Begin mapping
            var entries_to_map = pages - mapped_pages;
            var pages_step: u28 = 1;

            if (pte_flags.large) {
                switch (max_pt) {
                    1 => {
                        pages_step = utils.gb_size / page_size;
                        entries_to_map /= pages_step;
                    },
                    2 => {
                        pages_step = pages_per_2mb;
                        entries_to_map /= pages_step;
                    },
                    else => unreachable,
                }
            }

            while (entries_to_map > 0 and pte_idx < page_table_size) : ({
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

            std.debug.assert(pte_idx == 512);

            while (pt_stack[pt_idx - 1] == null) {
                pt_idx -= 1;
            }

            pt_idx -= 1;
            pte = pt_stack[pt_idx].?;
            pte_idx = @truncate((@intFromPtr(pte) & 0xFFF) / @sizeOf(PageTableEntry));

            std.debug.assert(pte_idx > 0);
        }
    }

    unreachable;
}

fn correctMmapFlags(flags: vm.MapFlags, virt: usize, phys: usize, pages: u32) vm.MapFlags {
    var result = flags;

    if (flags.large) {
        if (pages < pages_per_2mb or
            (virt % (2 * utils.mb_size) != 0 or
            phys % (2 * utils.mb_size) != 0)) result.large = false;
    }

    return result;
}

fn remapLarge(pte: *PageTableEntry, is_gb_page: bool) vm.Error!void {
    var template_pte = pte.*;
    template_pte.size = if (is_gb_page) 1 else 0;

    const pt = allocPt() orelse return vm.Error.NoMemory;

    pte.base = @truncate(@intFromPtr(vm.getPhysLma(pt)) / page_size);
    pte.size = 0;
    pte.global = 0;

    const pages_step: u16 = if (is_gb_page) pages_per_2mb else 1;

    for (0..page_table_size) |i| {
        pt[i] = template_pte;
        template_pte.base += pages_step;
    }
}
