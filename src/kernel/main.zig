const std = @import("std");

const arch = utils.arch;
const boot = @import("boot.zig");
const dev = @import("dev.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

pub const panic = @import("panic.zig").panic;

/// High-level entry point for the kernel. Uses **System V ABI**.
/// This function is called from architecture dependent code:
/// see `arch.startImpl`.
/// 
/// Can be accessed from inline assembly just as `main`.
/// 
/// Should never return.
export fn main() noreturn {
    defer @panic("reached end of the main");

    arch.preinit();

    init(vm);

    log.warn("Used memory: {} KB", .{vm.PageAllocator.getAllocatedPages() * vm.page_size / utils.kb_size});

    init(dev);

    log.info("Kernel startup at CPU: {}", .{arch.getCpuIdx()});
    log.info("CPUs detected: {}", .{boot.getCpusNum()});
}

fn init(comptime Module: type) void {
    Module.init() catch |err| {
        log.err("Can't initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        utils.halt();

        unreachable;
    };
}
