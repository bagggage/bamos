// @noexport

//! # Kernel entry point

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = utils.arch;
const boot = @import("boot.zig");
const dev = @import("dev.zig");
const logger = @import("logger.zig");
const log = std.log;
const smp = @import("smp.zig");
const utils = @import("utils.zig");
const vfs = @import("vfs.zig");
const video = @import("video.zig");
const vm = @import("vm.zig");

pub const panic = @import("panic.zig").panic;

pub const std_options = std.Options {
    .logFn = logger.defaultLog,
    .log_level = switch (builtin.mode) {
        .Debug,
        .ReleaseSafe => .debug,
        .ReleaseSmall,
        .ReleaseFast => .info
    }
};

/// High-level entry point for the kernel. Uses **System V ABI**.
/// This function is called from architecture dependent code:
/// see `arch.startImpl`.
///
/// Can be accessed from inline assembly just as `main`.
///
/// Should never return.
pub export fn main() noreturn {
    defer @panic("reached end of the main");

    smp.preinit();
    arch.preinit();

    init(smp);

    smp.initCpu();

    {
        const cpu = arch.getCpuInfo();
        log.info("CPUs detected: {}, vendor: {s}, model: {s}: {} MHz", .{
            smp.getNum(),
            @tagName(cpu.vendor),
            cpu.getName(),
            cpu.base_frequency
        });
    }

    init(vm);
    log.warn("Used memory: {} KB", .{vm.PageAllocator.getAllocatedPages() * vm.page_size / utils.kb_size});

    init(video.terminal);
    logger.switchFromEarly();

    smp.initAll();

    init(vfs);
    init(dev);
}

fn init(comptime Module: type) void {
    Module.init() catch |err| {
        log.err("Can't initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        utils.halt();

        unreachable;
    };
}
