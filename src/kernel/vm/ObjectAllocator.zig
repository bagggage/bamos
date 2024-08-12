/// Object memory allocator.
const std = @import("std");

const boot = @import("../boot.zig");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const FreeList_t = utils.SList(void);
const FreeNode = FreeList_t.Node;
const ArenaList_t = utils.SList(Arena);
const ArenaNode = ArenaList_t.Node;

const Arena = struct {
    pool_base: u32 = undefined,
    alloc_num: u32 = 0,

    next_ptr: usize = undefined,

    free_list: FreeList_t = FreeList_t{},

    pub fn init(phys_pool: usize) Arena {
        return Arena{ .pool_base = @truncate(phys_pool / vm.page_size), .next_ptr = vm.getVirtDma(phys_pool) };
    }

    pub fn alloc(self: *Arena, obj_size: usize) usize {
        defer self.alloc_num += 1;

        if (self.free_list.first != null) {
            const node = self.free_list.popFirst().?;
            return @intFromPtr(node);
        }

        const result = self.next_ptr;
        self.next_ptr += obj_size;

        return result;
    }

    pub fn free(self: *Arena, obj_addr: usize, obj_size: usize) void {
        defer self.alloc_num -= 1;

        if (self.next_ptr == obj_addr + obj_size) {
            self.next_ptr -= obj_size;
        } else {
            const node: *FreeNode = @ptrFromInt(obj_addr);
            self.free_list.prepend(node);
        }
    }

    pub fn contains(self: *Arena, obj_addr: usize, pool_size: usize) bool {
        const begin = vm.getVirtDma(@as(usize, self.pool_base) * vm.page_size);
        const end = begin + pool_size;

        return obj_addr >= begin and obj_addr < end;
    }
};

const Self = @This();

arenas: ArenaList_t = ArenaList_t{},
arena_capacity: u32 = undefined,
arena_rank: u32 = undefined,
obj_size: usize = undefined,

const arenas_tar_capacity = 256;
var arenas_alloc: vm.BucketAllocator = undefined;

pub fn initOmaSystem() vm.Error!void {
    const pool_size = arenas_tar_capacity * @sizeOf(ArenaNode);
    const pool_pages = std.math.divCeil(comptime_int, pool_size, vm.page_size) catch unreachable;

    comptime std.debug.assert(std.math.isPowerOfTwo(pool_pages));

    const mem_pool = boot.alloc(pool_pages) orelse return vm.Error.NoMemory;
    const virt_pool = vm.getVirtDma(mem_pool);

    arenas_alloc = vm.BucketAllocator.initRaw(ArenaNode, virt_pool, pool_pages);
}

pub fn init(comptime T: type) Self {
    if (@sizeOf(T) < @sizeOf(FreeNode)) {
        @compileError(std.fmt.comptimePrint("Object size must be at least {} bytes.", .{@sizeOf(FreeNode)}));
    }

    const pages = std.math.divCeil(comptime_int, @sizeOf(T) * 128, vm.page_size) catch unreachable;

    return initSized(@sizeOf(T), pages);
}

pub fn initSized(obj_size: usize, pages: u32) Self {
    std.debug.assert(obj_size >= @sizeOf(FreeNode));

    const rank: u32 = std.math.log2_int_ceil(u32, @truncate(pages));
    const real_pages = @as(u32, 1) << @truncate(rank);
    const real_capacity: u32 = (real_pages * vm.page_size) / @as(u32, @truncate(obj_size));

    std.debug.assert(real_capacity > 1);

    return Self{ .arena_capacity = real_capacity, .arena_rank = rank, .obj_size = obj_size };
}

pub fn initRaw(obj_size: usize, pool_phys: usize, pool_pages: u32) vm.Error!Self {
    var result = initSized(obj_size, pool_pages);

    const real_pages = @as(u32, 1) << @truncate(result.arena_rank);
    std.debug.assert(real_pages == pool_pages);

    const node = makeArena(pool_phys) orelse return vm.Error.NoMemory;
    result.arenas.prepend(node);

    return result;
}

pub fn alloc(self: *Self, comptime T: type) ?*T {
    var node = self.arenas.first;

    while (node) |arena| : (node = arena.next) {
        if (arena.data.alloc_num < self.arena_capacity) break;
    }

    var arena: *ArenaNode = undefined;

    if (node) |ptr| {
        arena = ptr;
    } else {
        arena = self.newArena() orelse return null;
    }

    const result: *T = @ptrFromInt(arena.data.alloc(self.obj_size));
    return result;
}

pub fn free(self: *Self, obj_ptr: anytype) void {
    comptime {
        const type_info = @typeInfo(@TypeOf(obj_ptr));
        switch (type_info) {
            .Pointer => |ptr| if (ptr.size != .One) @compileError("Argument type must be a pointer to one object"),
            else => @compileError("Argument type must be a pointer to one object"),
        }
    }

    const obj_addr = @intFromPtr(obj_ptr);
    const arena_size: usize = (@as(u32, 1) << @truncate(self.arena_rank)) * vm.page_size;

    var node = self.arenas.first;

    while (node) |arena| : (node = arena.next) {
        if (arena.data.contains(obj_addr, arena_size)) {
            arena.data.free(obj_addr, self.obj_size);

            if (arena.data.alloc_num == 0) self.deleteArena(arena);
            return;
        }
    }

    unreachable;
}

fn makeArena(pool_phys: usize) ?*ArenaNode {
    const node = arenas_alloc.alloc(ArenaNode) orelse return null;
    node.data = Arena.init(pool_phys);

    return node;
}

fn newArena(self: *Self) ?*ArenaNode {
    const node = arenas_alloc.alloc(ArenaNode) orelse return null;
    const mem_pool = vm.PageAllocator.alloc(self.arena_rank);

    if (mem_pool == null) {
        arenas_alloc.free(node);
        return null;
    }

    self.arenas.prepend(node);
    node.data = Arena.init(mem_pool.?);

    return node;
}

fn deleteArena(self: *Self, arena: *ArenaNode) void {
    self.arenas.remove(arena);
    vm.PageAllocator.free(arena.data.pool_base * vm.page_size, self.arena_rank);
}
