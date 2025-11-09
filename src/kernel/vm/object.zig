//! Template OMA allocation wrapper

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const List = utils.List;
const SList = utils.SList;

const default_oma_capacity = 128;

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

    allocator: Allocator,
    capacity: ?comptime_int = null
};

pub fn new(T: type) ?*T {
    const config: AllocatorConfig = T.alloc_config;
    const AllocatableType = T;

    const alloc_result: *AllocatableType = switch (comptime config.allocator) {
        .gpa => vm.alloc(AllocatableType),
        .safe_oma => getSafeOma(T, AllocatableType).alloc(),
        .oma => getOma(T, AllocatableType).alloc(AllocatableType)
    } orelse return null;

    return alloc_result;
}

pub fn free(T: type, ptr: *T) void {
    const config: AllocatorConfig = T.alloc_config;
    const AllocatableType = T;

    switch (comptime config.allocator) {
        .gpa => vm.free(ptr),
        .safe_oma => getSafeOma(T, AllocatableType).free(ptr),
        .oma => getOma(T, AllocatableType).free(ptr)
    }
}

pub inline fn delete(T: type, ptr: *T) void {
    ptr.deinit();
    free(T, ptr);
}

