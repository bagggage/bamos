/// Universal memory allocator.

const std = @import("std");

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const max_small_size = vm.page_size / 2;
const min_size = 16;

const oma_pool_len = std.math.log2(max_small_size) - std.math.log2(min_size);
const oma_min_capacity = 16;

var oma_pool: [oma_pool_len]vm.ObjectAllocator = init_oma_pool();
var huge_alloc_table: std.AutoArrayHashMap(u32, u8) = undefined;

comptime {
    @compileLog(@sizeOf(huge_alloc_table));
}

pub inline fn alloc(size: usize) ?*void {
    std.debug.assert(size > 0 and size < (vm.PageAllocator.max_alloc_pages * vm.page_size));

    return if (size <= max_small_size) allocSmall(@truncate(size)) else allocHuge(@truncate(size));
}

pub inline fn free(mem: ?*void) void {
    if (mem == null) return;

    const addr: usize = @intFromPtr(mem.?);
    const phys = vm.getPhysDma(addr);

    if (huge_alloc_table.get(phys)) |rank| {
        vm.PageAllocator.free(phys, rank);
    } else {}

    unreachable;
}

fn allocSmall(size: u32) ?*void {
    const rank = std.math.log2_int_ceil(u32, size) - std.math.log2(min_size);

    return oma_pool[rank].alloc(void);
}

fn allocHuge(size: u32) ?*void {
    const pages = std.math.divCeil(u32, size, vm.page_size) catch unreachable;

    if (pages > vm.PageAllocator.max_alloc_pages) return null;

    const rank = std.math.log2_int_ceil(u32, pages);
    const phys_addr = vm.PageAllocator.alloc(rank);

    if (phys_addr) |addr| {
        const base: u32 = @truncate(addr / vm.page_size);

        huge_alloc_table.put(base, rank) catch {
            vm.PageAllocator.free(phys_addr, rank);
            return null;
        };

        return @as(*void, @ptrFromInt(vm.getVirtDma(addr)));
    }

    return null;
}

fn init_oma_pool() [oma_pool_len]vm.ObjectAllocator {
    var result: [oma_pool_len]vm.ObjectAllocator = undefined;

    const min_rank = std.math.log2(min_size);
    const max_rank = std.math.log2(max_small_size);

    inline for (min_rank..max_rank) |rank| {
        const size = @as(u32, 1) << @truncate(rank);
        const i = rank - min_rank;

        const pages_num = std.math.divCeil(u32, size * oma_min_capacity, vm.page_size) catch unreachable;
        const pages = @as(u32, 1) << @truncate(std.math.log2_int_ceil(u32, pages_num));

        result[i] = vm.ObjectAllocator.initSized(size, pages);
    }

    return result;
}
