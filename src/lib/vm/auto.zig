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

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const opts = @import("opts");

const vm = @import("../vm.zig");

const ExternOma = extern struct {
    payload: [@sizeOf(vm.ObjectAllocator)]u8 align(@alignOf(vm.ObjectAllocator)),

    fn init(comptime oma: vm.ObjectAllocator) ExternOma {
        comptime var self: ExternOma = undefined;
        @memcpy(std.mem.asBytes(&self), std.mem.asBytes(&oma));

        return self;
    }
};

pub const config_member_name = "alloc_config";

pub const Config = struct {
    pub const Allocator = enum {
        oma,
        gpa,
    };

    allocator: Allocator,
    capacity: ?comptime_int = null,
};

pub fn alloc(T: type) ?*T {
    comptime assertIsAllocatable(T);

    const config: Config = T.alloc_config;
    return switch (comptime config.allocator) {
        .gpa => vm.gpa.create(T),
        .oma => getOma(T).alloc(T)
    };
}

pub fn free(T: type, ptr: *T) void {
    comptime assertIsAllocatable(T);

    const config: Config = T.alloc_config;
    switch (comptime config.allocator) {
        .gpa => vm.gpa.free(ptr),
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

fn getOma(comptime T: type) *vm.ObjectAllocator {
    const oma_name = comptime kernelOmaName(T);
    const size = @sizeOf(T);
    const capacity = T.alloc_config.capacity orelse vm.ObjectAllocator.default_capacity;

    if (comptime opts.is_kernel and oma_name != null) { // Internal kernel code
        const Static = opaque {
            pub var oma: ExternOma = .init(vm.ObjectAllocator.initCapacity(size, capacity));
        };

        @export(&Static.oma, .{ .name = oma_name.? });
        return @ptrCast(&Static.oma);
    } else if (comptime oma_name) |sym| { // Kernel modules
        const oma = @extern(*ExternOma, .{
            .name = sym,
            .library_name = "kernel",
        });
        return @ptrCast(oma);
    } else { // Non-kernel structs
        const Static = opaque {
            pub var oma: vm.ObjectAllocator = .initCapacity(size, capacity);
        };
        return &Static.oma;
    }
}

fn kernelOmaName(comptime T: type) ?[]const u8 {
    const type_name = @typeName(T);
    const kernel_prefix = "kernel.";

    if (comptime !std.mem.startsWith(u8, type_name, kernel_prefix)) return null;

    return type_name[kernel_prefix.len..];
}
