//! # Virtual Memory Management
//! Provides an interface for virtual memory management in the system.
//! It includes various memory allocators, page table management, and memory mapping
//! utilities.

const std = @import("std");

const arch = @import("utils.zig").arch;
const boot = @import("boot.zig");
const utils = @import("utils.zig");
const text_output = @import("video.zig").text_output;
const log = @import("log.zig");

/// The size of a memory page, specific to the architecture.
pub const page_size = arch.vm.page_size;
/// The start virtual address of the kernel in memory.
pub const kernel_start = &boot.kernel_elf_start;
pub const dma_start = arch.vm.dma_start;
pub const dma_size = arch.vm.dma_size;
pub const dma_end = arch.vm.dma_end;
/// The start address of the kernel heap.
pub const heap_start = arch.vm.heap_start;

pub const PageTable = arch.vm.PageTable;

pub const PageAllocator = @import("vm/PageAllocator.zig");
pub const ObjectAllocator = @import("vm/ObjectAllocator.zig");
pub const BucketAllocator = @import("vm/BucketAllocator.zig");
pub const UniversalAllocator = @import("vm/UniversalAllocator.zig");
pub const Heap = utils.Heap;

/// Allocates a new page table and zeroing all entries.
pub const allocPt = arch.vm.allocPt;
/// Frees a page table.
pub const freePt = arch.vm.freePt;
/// Gets the current page table from the specific cpu register.
pub const getPt = arch.vm.getPt;
/// Sets the given page table to the specific cpu register.
pub const setPt = arch.vm.setPt;
/// Logs the contents of a page table.
pub const logPt = arch.vm.logPt;

/// Maps a virtual memory range to a physical memory range.
pub const mmap = arch.vm.mmap;

/// General-purpose kernel memory allocation function.
pub const kmalloc = UniversalAllocator.alloc;
/// General-purpose kernel memory deallocation function.
pub const kfree = UniversalAllocator.free;

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

/// Error types that can occur during memory management operations.
pub const Error = error{
    Uninitialized,
    NoMemory,
};

var root_pt: *PageTable = undefined;

/// The kernel heap used for allocation virtual address ranges.
var heap = Heap.init(heap_start);

/// Initializes the virtual memory management system. Must be called only once.
///
/// This function sets up the PageAllocator, ObjectAllocator's system and the architecture-specific
/// virtual memory system. It also maps initial memory regions based on the kernel's memory mappings.
///
/// - Returns: An error if the initialization fails.
pub fn init() Error!void {
    try ObjectAllocator.initOmaSystem();
    try PageAllocator.init();

    try arch.vm.init();

    root_pt = allocPt() orelse return Error.NoMemory;

    const mappings = try boot.getMappings();

    for (mappings[0..]) |map_entry| {
        try mmap(
            map_entry.virt, map_entry.phys,
            map_entry.pages, map_entry.flags,
            root_pt
        );
    }

    boot.freeMappings(mappings);
    setPt(root_pt);
}

const intPtrErrorStr = "Only integer and pointer types are acceptable";

/// Translates a physical address to a virtual (DMA) address.
/// This is the fastest address transalition.
///
/// - `address`: The physical address to translate.
/// - Returns: The translated virtual address.
pub inline fn getVirtDma(address: anytype) @TypeOf(address) {
    const typeInfo = @typeInfo(@TypeOf(address));

    return switch (typeInfo) {
        .Int, .ComptimeInt => address + arch.vm.dma_start,
        .Pointer => @ptrFromInt(@intFromPtr(address) + arch.vm.dma_start),
        else => @compileError(intPtrErrorStr),
    };
}

/// Translates a virtual address of the direct memory access (DMA) region to a physical.
/// Can be used only with address returned from `getVirtDma`, UB otherwise.
///
/// - `address`: The virtual address to translate.
/// - Returns: The translated physical address.
pub inline fn getPhysDma(address: anytype) @TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    return switch (type_info) {
        .Int, .ComptimeInt => address - dma_start,
        .Pointer => @ptrFromInt(@intFromPtr(address) - dma_start),
        else => @compileError(intPtrErrorStr),
    };
}

/// Retrieves the physical address associated with a virtual address by a specific page table.
///
/// - `address`: The virtual address to translate.
/// - `pt`: The page table to use for translation.
/// - Returns: The corresponding physical address or `null` if the address isn't mapped.
pub inline fn getPhysPt(address: anytype, pt: *const PageTable) ?@TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    _ = switch (type_info) {
        .Int, .ComptimeInt, .Pointer => 0,
        else => @compileError(intPtrErrorStr),
    };

    const virt = switch (type_info) {
        .Pointer => @intFromPtr(address),
        else => address,
    };

    if (virt >= dma_start and virt < dma_end) return getPhysDma(address);

    const phys = arch.vm.getPhys(virt, pt) orelse return null;

    return switch (type_info) {
        .Pointer => @ptrFromInt(phys),
        else => phys,
    };
}

/// Retrieves the physical address associated with a virtual address using the current page table.
///
/// - `address`: The virtual address to translate.
/// - Returns: The corresponding physical address or `null` if the address isn't mapped.
pub inline fn getPhys(address: anytype) ?@TypeOf(address) {
    return getPhysPt(address, getPt());
}

/// Maps a physical memory to a virtual address in the cache disabled MMIO (Memory-Mapped I/O) space.
/// Should be used for memory mapped registers and other devices memory.
///
/// - `phys`: The physical address to map.
/// - `pages`: The number of pages to map.
/// - Returns: The virtual address where the region is mapped or an error if the operation fails.
pub inline fn mmio(phys: usize, pages: u32) Error!usize {
    std.debug.assert(pages > 0);

    const virt = heap.reserve(pages);

    try mmap(
        virt, phys, pages,
        .{ .write = true, .global = true, .cache_disable = true },
        root_pt
    );

    return virt;
}

/// Unmaps a previously mapped MMIO (Memory-Mapped I/O) region.
///
/// - `virt`: The virtual address returned by `mmio`.
/// - `pages`: The number of pages, must be the same as in `mmio` call.
pub inline fn unmmio(virt: usize, pages: u32) void {
    std.debug.assert(virt >= heap_start and pages > 0);

    heap.release(virt, pages);

    // It is a lazy unmap, so we don't have to unmap the region directly,
    // it will be remapped for the next allocation.
}

/// Allocates new page table and maps all neccessary kernel units.
/// Kernel mapping is optimized by coping a few entries from top level table of `root_pt`. 
///
/// - Returns: A pointer to the new page table or `null` if allocation fails.
pub inline fn newPt() ?*PageTable {
    const pt = allocPt() orelse return null;
    arch.vm.clonePt(root_pt, pt);

    return pt;
}