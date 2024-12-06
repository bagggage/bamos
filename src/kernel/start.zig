// @noexport

//! Low-level entry point for the kernel.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

/// High-level entry point for the kernel.
extern fn main() noreturn;

/// The `_start` function delegates to the `startImpl` function, defined in the architecture-specific 
/// `utils.zig` module. The `startImpl` is responsible for setting up the initial CPU state 
/// and then jumping to the `main` function.
pub export fn _start() callconv(.Naked) noreturn {
    @import("utils.zig").arch.startImpl();
}
