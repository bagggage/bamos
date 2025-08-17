//! # Virtual Memory Management
//! 
//! Provides an interface for virtual memory management in the system.
//! It includes various memory allocators, page table management, and memory mapping
//! utilities.

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const arch = @import("utils.zig").arch;
const boot = @import("boot.zig");
const log = std.log.scoped(.vm);
const smp = @import("smp.zig");
const utils = @import("utils.zig");

/// The size of a memory page, specific to the architecture.
pub const page_size = arch.vm.page_size;
/// The start virtual address of the kernel in memory.
/// @noexport
pub const kernel_start = &boot.kernel_elf_start;
/// @noexport
pub const kernel_end = &boot.kernel_elf_end;

pub const lma_start = arch.vm.lma_start;

pub const max_user_heap_addr = arch.vm.max_user_heap_addr;
pub const max_userspace_addr = arch.vm.max_userspace_addr;

pub const max_phys_pages = std.math.maxInt(u32);

pub const PageTable = arch.vm.PageTable;
pub const VirtualRegion = @import("vm/VirtualRegion.zig");

pub const BucketAllocator = @import("vm/BucketAllocator.zig");
pub const cache = @import("vm/cache.zig");
pub const Heap = utils.Heap;
pub const obj = @import("vm/object.zig");
pub const ObjectAllocator = @import("vm/ObjectAllocator.zig");
pub const PageAllocator = @import("vm/PageAllocator.zig");
pub const UniversalAllocator = @import("vm/UniversalAllocator.zig");

/// Thread-safe Object memory allocator wrapper.
/// Combination of the `ObjectAllocator` and `Spinlock`.
pub fn SafeOma(comptime T: type) type {
    return struct {
        const Self = @This();

        oma: ObjectAllocator = ObjectAllocator.init(T),
        lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

        pub inline fn alloc(self: *Self) ?*T {
            self.lock.lock();
            defer self.lock.unlock();

            return self.oma.alloc(T);
        }

        pub inline fn free(self: *Self, obj_ptr: *anyopaque) void {
            self.lock.lock();
            defer self.lock.unlock();

            self.oma.free(obj_ptr);
        }

        pub inline fn init(comptime capacity: usize) Self {
            return .{
                .oma = ObjectAllocator.initCapacity(@sizeOf(T), capacity)
            };
        }

        pub inline fn deinit(self: *Self) void {
            self.oma.deinit();
        }
    };
}

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
/// 
/// - `virt`: base virtual address to which physicall region must be mapped.
/// - `phys`: region base physical address.
/// - `pages`: number of pages to map.
/// - `flags`: flags to specify (see `vm.MapFlags` structure).
/// - `page_table`: target page table.
pub const mmap = arch.vm.mmap;
pub const unmap = arch.vm.unmap;

pub inline fn lmaSize() usize { return lmaEnd() - lma_start; }

pub const lmaEnd = arch.vm.lmaEnd;
pub const heapStart = arch.vm.heapStart;

/// General-purpose kernel memory allocation function.
pub const malloc = UniversalAllocator.alloc;
/// General-purpose kernel memory deallocation function.
pub const free = UniversalAllocator.free;

/// General-purpose kernel allocation function to allocate
/// object of the specific type.
pub inline fn alloc(comptime T: type) ?*T {
    return @alignCast(@ptrCast(malloc(@sizeOf(T))));
}

/// Kernel high-level general purpose allocator interface.
/// 
/// Implements `std.mem.Allocator` interface for use
/// with Zig Standard Library `std`.
pub var std_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &std_vtable
};
const std_vtable = opaque {
    pub const vtable = std.mem.Allocator.VTable{
        .alloc = stdAlloc,
        .resize = stdResize,
        .remap = stdRemap,
        .free = stdFree,
    };

    fn stdAlloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const result = malloc(len) orelse return null;
        // Check if pointer is aligned
        // std.debug.assert((@intFromPtr(result) % (@as(u32, 1) << @truncate(ptr_align))) == 0);
        return @ptrCast(result);
    }

    fn stdFree(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        free(buf.ptr);
    }

    fn stdResize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return buf.len >= new_len;
    }

    fn stdRemap(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        const new_buf: [*]u8 = @ptrCast(malloc(new_len) orelse return null);

        if (buf.len < new_len) {
            @memcpy(new_buf[0..buf.len], buf);
        } else {
            @memcpy(new_buf[0..new_len], buf[0..new_len]);
        }

        free(buf.ptr);
        return new_buf;
    }
}.vtable;

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
};

var root_pt: *PageTable = undefined;

/// The kernel heap used for allocation virtual address ranges.
var heap: Heap = undefined;
var heap_lock = utils.Spinlock.init(.unlocked);

/// Initializes the virtual memory management system. Must be called only once.
/// 
/// This function sets up the `PageAllocator`, `ObjectAllocator's` system and the architecture-specific
/// virtual memory system. It also maps initial memory regions based on the kernel's memory mappings.
/// 
/// - Returns: An error if the initialization fails.
pub fn init() Error!void {
    heap = .init(heapStart());

    try ObjectAllocator.initOmaSystem();
    try PageAllocator.init();

    try arch.vm.init();

    root_pt = allocPt() orelse return Error.NoMemory;

    const mappings = try boot.getMappings();
    defer boot.freeMappings(mappings);

    for (mappings[0..]) |map_entry| {
        try mmap(
            map_entry.virt, map_entry.phys,
            map_entry.pages, map_entry.flags,
            root_pt
        );
    }

    setPt(root_pt);
}

const intPtrErrorStr = "Only integer and pointer types are acceptable";

/// Translates a physical address to a virtual (LMA) address.
/// This is the fastest address transalition.
/// 
/// - `address`: the physical address to translate.
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
/// 
/// - `address`: the virtual address to translate.
/// - Returns: The translated physical address.
pub inline fn getPhysLma(address: anytype) @TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    return switch (type_info) {
        .int, .comptime_int => address - lma_start,
        .pointer => @ptrFromInt(@intFromPtr(address) - lma_start),
        else => @compileError(intPtrErrorStr),
    };
}

/// Translate the virtual address into physical address via specific page table.
/// 
/// - `address`: The virtual address to translate.
/// - `pt`: The page table to use for translation.
/// - Returns: The corresponding physical address or `null` if the address isn't mapped.
pub inline fn getPhysPt(address: anytype, pt: *const PageTable) ?@TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    _ = switch (type_info) {
        .int, .comptime_int, .pointer => 0,
        else => @compileError(intPtrErrorStr),
    };

    const virt = switch (type_info) {
        .pointer => @intFromPtr(address),
        else => address,
    };

    if (virt >= lma_start and virt < lmaEnd()) return getPhysLma(address);

    const phys = arch.vm.getPhys(virt, pt) orelse return null;

    return switch (type_info) {
        .pointer => @ptrFromInt(phys),
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

    const virt = blk: {
        heap_lock.lock();
        defer heap_lock.unlock();

        break :blk heap.reserve(pages);
    };

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
    std.debug.assert(virt >= heapStart() and pages > 0);

    heap_lock.lock();
    defer heap_lock.unlock();

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

pub fn pageFaultHandler(addr: usize, cause: FaultCause, userspace: bool) bool {
    const sys = @import("sys.zig");

    log.warn(
        \\{raw-log}Page Fault (CPU {}) - {}: 
        \\ address: 0x{x:.>16}; cause: {s}
        \\ userspace: {}
        ++ "\n"
        , .{
            smp.getIdx(), sys.time.getTime(), addr,
            @tagName(cause), userspace
        }
    );

    return false;
}