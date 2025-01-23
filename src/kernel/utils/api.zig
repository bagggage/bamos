//! # API Helper
//! 
//! Implements some useful comptime utilities
//! that make available to simple export and import
//! Zig functions without making a wrappers with `callconv(.C)`.

const std = @import("std");

pub fn scoped(comptime Scope: type) type {
    const scope_name = @typeName(Scope);

    return opaque {
        /// @export
        pub fn externFn(comptime func: anytype, comptime name_tag: @Type(.enum_literal)) @TypeOf(&func) {
            const func_ptr = comptime @extern(*const anyopaque, .{ .name = scope_name ++ "." ++ @tagName(name_tag) });
            return @ptrCast(func_ptr);
        }
    };
}