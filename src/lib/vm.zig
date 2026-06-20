//! # Virtual Memory Management
//! 
//! Provides an interface for virtual memory management in the system.
//! It includes various memory allocators, page table management, and memory mapping
//! utilities.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("bindings.zig");

const arch = @import("kernel.zig").arch;
const lib = @import("lib.zig");

/// The size of a memory page, specific to the architecture.
pub const page_size = arch.vm.page_size;
pub const page_shift = std.math.log2_int(u16, page_size);

pub const lma_start = arch.vm.lma_start;

pub const max_user_heap_addr = arch.vm.max_user_heap_addr;
pub const max_userspace_addr = arch.vm.max_userspace_addr;

pub const max_phys_pages = std.math.maxInt(u32);

pub const auto = @import("vm/auto.zig");
pub const cache = @import("vm/cache.zig");
pub const gpa = @import("vm/gpa.zig");
pub const ObjectAllocator = @import("vm/ObjectAllocator.zig");
pub const Page = @import("vm/Page.zig");
pub const PageAllocator = @import("vm/PageAllocator.zig");
pub const PageTable = arch.vm.PageTable;
pub const VirtualRegion = @import("vm/VirtualRegion.zig");

/// Gets the current page table from the specific cpu register.
pub const getPageTable = arch.vm.getPageTable;
/// Sets the given page table to the specific cpu register.
pub const setPageTable = arch.vm.setPageTable;

pub const lmaEnd = arch.vm.lmaEnd;
pub const heapStart = arch.vm.heapStart;

/// Checks if an address belongs to the userspace virtual memory range.
pub const isUserVirtAddr = arch.vm.isUserVirtAddr;

/// Mapping flags used to enable/disable specific features for memory pages.
pub const MapFlags = packed struct {
    pub const Caching = enum(u2) {
        write_back    = 0,
        write_throw   = 1,
        uncached      = 2,
        write_combine = 3,
    };

    none: bool = false,
    write: bool = false,
    user: bool = false,
    global: bool = false,
    large: bool = false,
    exec: bool = false,
    cache: Caching = .write_back,

    // Ensure that the size of `MapFlags` matches the size of a byte.
    comptime {
        std.debug.assert(@sizeOf(MapFlags) == @sizeOf(u8));
    }
};

pub const FaultCause = enum {
    read,
    write,
    exec,
};

/// Error types that can occur during memory management operations.
pub const Error = error {
    Uninitialized,
    NoMemory,
    MaxSize,
    SegFault,
};

const int_ptr_err_msg = "Only integer and pointer types are acceptable";

pub inline fn lmaSize() usize {
    return lmaEnd() - lma_start;
}

/// Translates a physical address to a virtual (LMA) address.
/// This is the fastest address transalition.
/// - Returns: The translated virtual address.
pub inline fn getVirtLma(address: anytype) @TypeOf(address) {
    const typeInfo = @typeInfo(@TypeOf(address));

    return switch (typeInfo) {
        .int, .comptime_int => blk: {
            assertLmaPhysAddress(address);
            break :blk address + lma_start;
        },
        .pointer => blk: {
            assertLmaPhysAddress(@intFromPtr(address));
            break :blk @ptrFromInt(@intFromPtr(address) + lma_start);
        },
        else => @compileError(int_ptr_err_msg),
    };
}

inline fn assertLmaPhysAddress(address: usize) void {
    if (comptime lib.is_debug == false) return;
    if (address >= lmaSize()) @panic("physical address out of LMA bounds");
}

/// Translates a virtual address of the linear memory access (LMA) region to a physical.
/// Can be used only with address returned from `getVirtLma`, UB otherwise.
/// - Returns: The translated physical address.
pub inline fn getPhysLma(address: anytype) usize {
    const type_info = @typeInfo(@TypeOf(address));

    return switch (type_info) {
        .int, .comptime_int => address - lma_start,
        .pointer => @intFromPtr(address) - lma_start,
        else => @compileError(int_ptr_err_msg),
    };
}

/// Retrieves the physical address associated with a virtual address using the current page table.
/// - Returns: The corresponding physical address or `null` if the address isn't mapped.
pub inline fn translateVirtToPhys(virt: usize) ?usize {
    if (virt >= lma_start and virt < lmaEnd()) return getPhysLma(virt);
    return getPageTable().translateVirtToPhys(virt);
}

/// Maps a physical memory to a virtual address in the cache disabled MMIO (Memory-Mapped I/O) space.
/// Should be used for memory mapped registers and other devices memory.
/// - `phys`: The physical address to map.
/// - `pages`: The number of pages to map.
/// - Returns: The virtual address where the region is mapped or an error if the operation fails.
pub inline fn mmio(phys: usize, pages: u32) Error!usize {
    std.debug.assert(pages > 0);

    const virt = heapReserve(pages);
    try getRootPt().map(
        virt, phys, pages,
        .{ .write = true, .global = true, .cache = .uncached },
    );

    return virt | (phys & (page_size -% 1));
}

/// Unmaps a previously mapped MMIO (Memory-Mapped I/O) region.
/// - `virt`: The virtual address returned by `mmio`.
/// - `pages`: The number of pages, must be the same as in `mmio` call.
pub inline fn unmmio(virt: usize, pages: u32) void {
    bindings.getInstance().vm.unmmio(virt, pages);
}

/// Allocates new page table and maps all neccessary kernel units.
/// Kernel mapping is optimized by coping a few entries from top level table of `root_pt`. 
/// - Returns: A pointer to the new page table or `null` if allocation fails.
pub inline fn createPageTable() ?*PageTable {
    return bindings.getInstance().vm.createPageTable();
}

pub inline fn getRootPt() *PageTable {
    return bindings.getInstance().vm.getRootPt();
}

/// Reserve virtual addresses region on kernel heap.
/// - `pages`: The number of pages to reserve.
/// - Returns: A base virtual address of the region.
pub inline fn heapReserve(pages: u32) usize {
    return bindings.getInstance().vm.heapReserve(pages);
}

/// Release virtual addresses region on kernel heap.
/// - `base`: A base virtual address of the region.
/// - `pages`: The number of pages related to region.
pub inline fn heapRelease(base: usize, pages: u32) void {
    return bindings.getInstance().vm.heapRelease(base, pages);
}

comptime {
    std.debug.assert(PageAllocator.max_rank <= std.math.maxInt(u8));
    std.debug.assert(PageAllocator.max_alloc_pages <= std.math.maxInt(u32));
}

pub inline fn rankToPages(rank: u8) u32 {
    return @as(u32, 1) << @intCast(rank);
}

pub inline fn rankToBytes(rank: u8) usize {
    return (@as(usize, 1) << @intCast(rank)) << page_shift;
}

pub inline fn bytesToRank(bytes: usize) u8 {
    return pagesToRank(bytesToPages(bytes));
}

pub inline fn bytesToPages(bytes: usize) u32 {
    return @intCast((bytes + page_size - 1) >> page_shift);
}

pub inline fn bytesToPagesExact(bytes: usize) u32 {
    return @intCast(bytes >> page_shift);
}

pub inline fn pagesToRank(pages: u32) u8 {
    return std.math.log2_int_ceil(u32, pages);
}

pub inline fn pagesToRankExact(pages: u32) u8 {
    return std.math.log2_int(u32, pages);
}
