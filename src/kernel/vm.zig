const std = @import("std");

const arch = @import("utils.zig").arch;
const boot = @import("boot.zig");
const utils = @import("utils.zig");
const text_output = @import("video.zig").text_output;
const log = @import("log.zig");

pub const page_size = arch.vm.page_size;
pub const kernel_start = &boot.kernel_elf_start;
pub const dma_start = arch.vm.dma_start;
pub const dma_size = arch.vm.dma_size;
pub const dma_end = arch.vm.dma_end;
pub const heap_start = arch.vm.heap_start;

pub const PageTable = arch.vm.PageTable;

pub const PageAllocator = @import("vm/PageAllocator.zig");
pub const ObjectAllocator = @import("vm/ObjectAllocator.zig");
pub const BucketAllocator = @import("vm/BucketAllocator.zig");
pub const UniversalAllocator = @import("vm/UniversalAllocator.zig");
pub const Heap = utils.Heap;

pub const allocPt = arch.vm.allocPt;
pub const freePt = arch.vm.freePt;
pub const getPt = arch.vm.getPt;
pub const setPt = arch.vm.setPt;
pub const logPt = arch.vm.logPt;

pub const mmap = arch.vm.mmap;

pub const kmalloc = UniversalAllocator.alloc;
pub const kfree = UniversalAllocator.free;

pub const MapFlags = packed struct {
    none: bool = false,
    write: bool = false,
    user: bool = false,
    global: bool = false,
    large: bool = false,
    exec: bool = false,
    cache_disable: bool = false,

    comptime {
        std.debug.assert(@sizeOf(MapFlags) == @sizeOf(u8));
    }
};

pub const Error = error{
    Uninitialized,
    NoMemory,
};

var root_pt: *PageTable = undefined;
var heap = Heap.init(heap_start);

pub fn init() Error!void {
    try ObjectAllocator.initOmaSystem();
    try PageAllocator.init();

    try arch.vm.init();

    root_pt = allocPt() orelse return Error.NoMemory;

    const mappings = try boot.getMappings();

    for (mappings[0..]) |map_entry| {
        try mmap(map_entry.virt, map_entry.phys, map_entry.pages, map_entry.flags, root_pt);
    }

    boot.freeMappings(mappings);
    setPt(root_pt);
}

const intPtrErrorStr = "Only integer and pointer types are acceptable";

pub inline fn getVirtDma(address: anytype) @TypeOf(address) {
    const typeInfo = @typeInfo(@TypeOf(address));

    return switch (typeInfo) {
        .Int, .ComptimeInt => address + arch.vm.dma_start,
        .Pointer => @ptrFromInt(@intFromPtr(address) + arch.vm.dma_start),
        else => @compileError(intPtrErrorStr),
    };
}

pub inline fn getPhysDma(address: anytype) @TypeOf(address) {
    const type_info = @typeInfo(@TypeOf(address));

    return switch (type_info) {
        .Int, .ComptimeInt => address - dma_start,
        .Pointer => @ptrFromInt(@intFromPtr(address) - dma_start),
        else => @compileError(intPtrErrorStr),
    };
}

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

pub inline fn getPhys(address: anytype) ?@TypeOf(address) {
    return getPhysPt(address, getPt());
}

pub inline fn mmio(phys: usize, pages: u32) Error!usize {
    std.debug.assert(pages > 0);

    const virt = heap.reserve(pages);

    try mmap(virt, phys, pages, .{ .write = true, .global = true, .cache_disable = true }, root_pt);

    return virt;
}

pub inline fn unmmio(virt: usize, pages: u32) void {
    std.debug.assert(virt >= heap_start and pages > 0);

    heap.release(virt, pages);

    // It is a lazy unmap, so we don't have to unmap the region directly,
    // it will be remapped for the next allocation.
}

pub inline fn new_pt() ?*PageTable {
    const pt = allocPt() orelse return null;
    arch.vm.clonePt(root_pt, pt);

    return pt;
}
