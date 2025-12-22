//! # Virtual Memory Management
//! 
//! Provides an interface for virtual memory management in the system.
//! It includes various memory allocators, page table management, and memory mapping
//! utilities.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = lib.arch;
const boot = @import("boot.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.vm);
const sched = @import("sched.zig");
const smp = @import("smp.zig");

/// The size of a memory page, specific to the architecture.
pub const page_size = arch.vm.page_size;
pub const page_shift = std.math.log2_int(u16, page_size);
/// The start virtual address of the kernel in memory.
pub const kernel_start = &boot.kernel_elf_start;
pub const kernel_end = &boot.kernel_elf_end;
pub const lma_start = arch.vm.lma_start;

pub const max_user_heap_addr = arch.vm.max_user_heap_addr;
pub const max_userspace_addr = arch.vm.max_userspace_addr;

pub const max_phys_pages = std.math.maxInt(u32);

pub const PageTable = arch.vm.PageTable;
pub const VirtualRegion = @import("vm/VirtualRegion.zig");

pub const auto = @import("vm/auto.zig");
pub const BucketAllocator = @import("vm/BucketAllocator.zig");
pub const cache = @import("vm/cache.zig");
pub const gpa = @import("vm/gpa.zig");
pub const ObjectAllocator = @import("vm/ObjectAllocator.zig");
pub const Page = @import("vm/Page.zig");
pub const PageAllocator = @import("vm/PageAllocator.zig");

/// Gets the current page table from the specific cpu register.
pub const getPageTable = arch.vm.getPageTable;
/// Sets the given page table to the specific cpu register.
pub const setPageTable = arch.vm.setPageTable;

pub inline fn lmaSize() usize { return lmaEnd() - lma_start; }
pub const lmaEnd = arch.vm.lmaEnd;
pub const heapStart = arch.vm.heapStart;

/// Checks if an address belongs to the userspace virtual memory range.
pub const isUserVirtAddr = arch.vm.isUserVirtAddr;

/// Mapping flags used to enable/disable specific features for memory pages.
pub const MapFlags = packed struct {
    none: bool = false,
    write: bool = false,
    user: bool = false,
    global: bool = false,
    large: bool = false,
    exec: bool = false,
    cache_disable: bool = false,

    // Ensure that the size of `MapFlags` matches the size of a byte.
    comptime {
        std.debug.assert(@sizeOf(MapFlags) == @sizeOf(u8));
    }
};

pub const FaultCause = enum {
    read,
    write,
    exec
};

/// Error types that can occur during memory management operations.
pub const Error = error {
    Uninitialized,
    NoMemory,
    MaxSize,
    SegFault,
};

var root_pt: *PageTable = undefined;

/// The kernel heap used for allocation virtual address ranges.
var heap: lib.Heap = undefined;
var heap_lock: lib.sync.Spinlock = .init(.unlocked);

/// Initializes the virtual memory management system. Must be called only once.
/// 
/// This function sets up the `PageAllocator`, `ObjectAllocator's` system and the architecture-specific
/// virtual memory system. It also maps initial memory regions based on the kernel's memory mappings.
/// 
/// - Returns: An error if the initialization fails.
pub fn init() !void {
    heap = .init(heapStart());

    try ObjectAllocator.initOmaSystem();
    try PageAllocator.init();

    try arch.vm.init();

    root_pt = PageTable.new() orelse return Error.NoMemory;

    const mappings = try boot.getMappings();
    defer boot.freeMappings(mappings);

    for (mappings[0..]) |map_entry| {
        try root_pt.map(
            map_entry.virt, map_entry.phys,
            map_entry.pages, map_entry.flags
        );
    }

    setPageTable(root_pt);

    try cache.init();
}

const intPtrErrorStr = "Only integer and pointer types are acceptable";

/// Translates a physical address to a virtual (LMA) address.
/// This is the fastest address transalition.
/// - Returns: The translated virtual address.
pub inline fn getVirtLma(address: anytype) @TypeOf(address) {
    const typeInfo = @typeInfo(@TypeOf(address));

    return switch (typeInfo) {
        .int, .comptime_int => address + lma_start,
        .pointer => @ptrFromInt(@intFromPtr(address) + lma_start),
        else => @compileError(intPtrErrorStr),
    };
}

/// Translates a virtual address of the linear memory access (LMA) region to a physical.
/// Can be used only with address returned from `getVirtLma`, UB otherwise.
/// - Returns: The translated physical address.
pub inline fn getPhysLma(address: anytype) @TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    return switch (type_info) {
        .int, .comptime_int => address - lma_start,
        .pointer => @ptrFromInt(@intFromPtr(address) - lma_start),
        else => @compileError(intPtrErrorStr),
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
/// 
/// - `phys`: The physical address to map.
/// - `pages`: The number of pages to map.
/// - Returns: The virtual address where the region is mapped or an error if the operation fails.
pub inline fn mmio(phys: usize, pages: u32) Error!usize {
    std.debug.assert(pages > 0);

    const virt = blk: {
        heap_lock.lock();
        defer heap_lock.unlock();

        break :blk heap.reserve(pages);
    };

    try root_pt.map(
        virt, phys, pages,
        .{ .write = true, .global = true, .cache_disable = true },
    );

    return virt;
}

/// Unmaps a previously mapped MMIO (Memory-Mapped I/O) region.
/// 
/// - `virt`: The virtual address returned by `mmio`.
/// - `pages`: The number of pages, must be the same as in `mmio` call.
pub inline fn unmmio(virt: usize, pages: u32) void {
    std.debug.assert(virt >= heapStart() and pages > 0);

    heap_lock.lock();
    defer heap_lock.unlock();

    heap.release(virt, pages);

    // It is a lazy unmap, so we don't have to unmap the region directly,
    // it will be remapped for the next allocation.
}

/// Allocates new page table and maps all neccessary kernel units.
/// Kernel mapping is optimized by coping a few entries from top level table of `root_pt`. 
/// - Returns: A pointer to the new page table or `null` if allocation fails.
pub inline fn createPageTable() ?*PageTable {
    const new_pt = PageTable.new() orelse return null;
    arch.vm.copyKernelMappings(root_pt, new_pt);

    return new_pt;
}

pub inline fn getRootPt() *PageTable {
    return root_pt;
}

/// Reserve virtual addresses region on kernel heap.
/// 
/// - `pages`: The number of pages to reserve.
/// - Returns: A base virtual address of the region.
pub inline fn heapReserve(pages: u32) usize {
    heap_lock.lock();
    defer heap_lock.unlock();

    return heap.reserve(pages);
}

/// Release virtual addresses region on kernel heap.
/// 
/// - `base`: A base virtual address of the region.
/// - `pages`: The number of pages related to region.
pub inline fn heapRelease(base: usize, pages: u32) void {
    heap_lock.lock();
    defer heap_lock.unlock();

    heap.release(base, pages);
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

pub inline fn pagesToRank(pages: u32) u8 {
    return std.math.log2_int_ceil(u32, pages);
}

pub inline fn pagesToRankExact(pages: u32) u8 {
    return std.math.log2_int(u32, pages);
}

pub fn pageFaultHandler(address: usize, cause: FaultCause, userspace: bool) bool {
    const sys = @import("sys.zig");

    if (userspace or arch.vm.isUserVirtAddr(address)) {
        const task = sched.getCurrentTask();
        if (task.spec == .user) {
            task.spec.user.process.pageFault(address, cause);
            return true;
        }
    }

    log.warn(
        \\Page Fault (CPU {}) - {f}: 
        \\ address: 0x{x:.>16}; cause: {s}
        \\ userspace: {}
        ++ "\n"
        , .{
            smp.getIdx(), sys.time.getTime(), address,
            @tagName(cause), userspace
        }
    );

    return false;
}
