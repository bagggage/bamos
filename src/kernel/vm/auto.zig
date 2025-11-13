//! # Allocation automation framework
//! 
//! This framework provides comptime utilities to save
//! time on manually managing allocators and writing helpers like `new`,
//! `alloc`, `free` or `delete` per each struct you want to be allocatable.
//! 
//! Instead define allocation config and make it public: `pub const alloc_config: vm.auto.Config`,
//! now you can use any `vm.auto` helper:
//! - `alloc()`
//! - `free()`
//! - `delete()`

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

pub const config_member_name = "alloc_config";

pub const Config = struct {
    pub const Allocator = enum {
        oma,
        gpa,
    };

    allocator: Allocator,
    capacity: ?comptime_int = null
};

pub fn alloc(T: type) ?*T {
    comptime assertIsAllocatable(T);

    const config: Config = T.alloc_config;
    return switch (comptime config.allocator) {
        .gpa => vm.alloc(T),
        .oma => getOma(T).alloc(T)
    };
}

pub fn free(T: type, ptr: *T) void {
    comptime assertIsAllocatable(T);

    const config: Config = T.alloc_config;
    switch (comptime config.allocator) {
        .gpa => vm.free(ptr),
        .oma => getOma(T).free(ptr)
    }
}

pub inline fn delete(T: type, ptr: *T) void {
    comptime assertIsAllocatable(T);

    ptr.deinit();
    free(T, ptr);
}

fn assertIsAllocatable(T: type) void {
    if (comptime @hasDecl(T, config_member_name)) {
        if (@TypeOf(@field(T, config_member_name)) == Config) return;
    }

    @compileError(
        @typeName(T) ++ " does not support 'vm.auto' framework, you may need to declare '" ++
        config_member_name ++ "' within the structure (see 'vm.auto')"
    );
}

fn getOma(T: type) *vm.ObjectAllocator {
    const Static = struct {
        pub var oma: vm.ObjectAllocator = .initCapacity(
            @sizeOf(T),
            T.alloc_config.capacity orelse vm.ObjectAllocator.default_capacity
        );
    };

    return &Static.oma;
}