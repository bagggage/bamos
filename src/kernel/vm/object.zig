//! Template OMA allocation wrapper

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const List = utils.List;
const SList = utils.SList;

const default_oma_capacity = 128;

fn AllocType(T: type) type {
    const wrapper: AllocatorConfig.Wrapper = T.alloc_config.wrapper;

    return switch (wrapper) {
        .none => T,
        .list_node => List(T).Node,
        .single_list_node => SList(T).Node
    };
}

fn getSafeOma(T: type, AllocatableType: type) *vm.SafeOma(AllocatableType) {
    const Static = struct {
        pub var oma: vm.SafeOma(AllocatableType) = .init(
            T.alloc_config.capacity orelse default_oma_capacity
        );
    };

    return &Static.oma;
}

fn getOma(T: type, AllocatableType: type) *vm.ObjectAllocator {
    const Static = struct {
        pub var oma: vm.ObjectAllocator = .initCapacity(
            @sizeOf(AllocatableType),
            T.alloc_config.capacity orelse default_oma_capacity
        );
    };

    return &Static.oma;
}

pub const AllocatorConfig = struct {
    pub const Allocator = enum {
        oma,
        safe_oma,
        gpa,
    };
    pub const Wrapper = enum {
        none,
        single_list_node,
        list_node,

        pub fn listNode(comptime T: type) Wrapper {
            const is_node = @hasField(T, "next") and @hasField(T, "data");
            if (comptime is_node == false)
                @compileError("Expected list node type, found: '"++@typeName(T)++"'");

            return if (@hasField(T, "prev")) .list_node else .single_list_node;
        }
    };

    allocator: Allocator,
    wrapper: Wrapper = .none,
    capacity: ?comptime_int = null
};

pub fn new(T: type) ?*T {
    const config: AllocatorConfig = T.alloc_config;
    const AllocatableType = AllocType(T);

    const alloc_result: *AllocatableType = switch (comptime config.allocator) {
        .gpa => vm.alloc(AllocatableType),
        .safe_oma => getSafeOma(T, AllocatableType).alloc(),
        .oma => getOma(T, AllocatableType).alloc(AllocatableType)
    } orelse return null;

    if (comptime T.alloc_config.wrapper == .none) {
        return alloc_result;
    } else {
        return &alloc_result.data;
    }
}

pub fn free(T: type, ptr: *T) void {
    const config: AllocatorConfig = T.alloc_config;
    const AllocatableType = AllocType(T);

    const src_ptr = switch (comptime config.wrapper) {
        .none => ptr,
        .list_node => asNode(T, ptr),
        .single_list_node => asSingleNode(T, ptr)
    };

    switch (comptime config.allocator) {
        .gpa => vm.free(src_ptr),
        .safe_oma => getSafeOma(T, AllocatableType).free(src_ptr),
        .oma => getOma(T, AllocatableType).free(src_ptr)
    }
}

pub inline fn delete(T: type, ptr: *T) void {
    ptr.deinit();
    free(T, ptr);
}

pub inline fn asNode(T: type, ptr: *T) *List(T).Node {
    return @fieldParentPtr("data", ptr);
}

pub inline fn asSingleNode(T: type, ptr: *T) *SList(T).Node {
    return @fieldParentPtr("data", ptr);
}