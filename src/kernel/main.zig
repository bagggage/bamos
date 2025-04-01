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
const sched = @import("sched.zig");
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

    preinit(dev);

    init(sched.executor);

    sched.startup(0, kernelStartupTask) catch |err| {
        log.err("startup failed: {s}", .{@errorName(err)});
        utils.halt();
    };
}

/// Specific task to finish kernel initialization.
/// This task is only for boot cpu.
fn kernelStartupTask() noreturn {
    init(video.terminal);
    logger.switchFromEarly();

    smp.initAll();

    for (1..smp.getNum()) |cpu| {
        sched.startup(@truncate(cpu), awaitTask) catch |err| {
            log.err("cpu {}: startup failed: {s}", .{cpu, @errorName(err)});
        };
    }

    init(vfs);
    init(dev);

    utils.halt();
}

/// Specific task to wait until kernel initialization is done
/// and run userspace after.
fn awaitTask() noreturn {
    log.debug("await: {}", .{smp.getIdx()});

    while (true) {
        //sched.executor.yeild();
    }
}

fn preinit(comptime Module: type) void {
    Module.preinit() catch |err| {
        log.err("Can't pre-initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        utils.halt();

        unreachable;
    };
}

fn init(comptime Module: type) void {
    Module.init() catch |err| {
        log.err("Can't initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        utils.halt();

        unreachable;
    };
}
