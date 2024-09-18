//! # Architecture implementation template

comptime {
    @compileError("This file is a template and shouldn't be imported or compiled");
}

/// - Virtual memory driver
pub const vm = @import("vm.zig");
/// - I/O Subsystem implementation
pub const io = @import("io.zig");

/// - `_start` function.
/// 
/// Kernel entry point implementation.
/// This function just should call the `main` function
/// located in the `main.zig` file, must be `inline`,
/// use `naked` calling convention and don't return.
/// 
/// The `main` function don't take any input arguments, marked as `noreturn`
/// and uses **System V ABI** calling convention. The only reason of using architecture
/// dependent `_start` implementation is to make able to prepare some things
/// like stack, before start execution.
/// 
/// See `main.zig`, `start.zig` for more information.
pub inline fn startImpl() noreturn {}

/// Preinitialization function.
/// 
/// This is the first function to call in the kernel
/// after getting control from the bootloader.
/// 
/// After returning from the function, the following things must be guaranteed:
/// 
/// - Code execution continues on only one CPU core.
/// - Early handling of hardware exceptions is enabled for the current core.
/// - The LMA region is accessible, and `boot.switchToLma()` has been called.
/// - The I/O subsystem functions are available.
/// - The core functions of the `arch` module are available.
/// - Everything necessary is configured and ready for further initialization
/// of the `vm` module, the interrupt system, and other subsystems.
pub fn preinit() void {}

/// This function should return the index of the processor core on which it was called.
/// For single-threaded systems, it should return zero.
/// 
/// May be marked as `inline` if possible.
pub fn getCpuIdx() u32 {}

/// This function is responsible for initialization
/// of architecture dependent devices and drivers in the
/// `dev` subsystem.
/// 
/// It's called when the platform bus is registered and ready for use.
pub fn devInit() !void {}
