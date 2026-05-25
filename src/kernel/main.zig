//! # Kernel entry point

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("opts");

const arch = lib.arch;
const boot = @import("boot.zig");
const config = @import("config.zig");
const dev = @import("dev.zig");
const lib = @import("lib.zig");
const logger = @import("logger.zig");
const log = std.log;
const sched = @import("sched.zig");
const smp = @import("smp.zig");
const sys = @import("sys.zig");
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
    },
    .log_scope_levels = &.{
        .{
            .level = if (lib.is_debug) .debug else .warn,
            .scope = .@"sys.call.trace"
        },
        .{ .level = .info, .scope = .@"sys.call" },
        .{ .level = .info, .scope = .pci },
        .{ .level = .info, .scope = .@"intr.except" },
        .{ .level = .info, .scope = .uacpi },
        //.{ .level = .warn, .scope = .@"sys.MapUnit" },
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

    if (!smp.bootCpu()) startNonBootCpu();

    arch.preinit();
    smp.init();

    log.info("{s} {s}", .{opts.os_name, opts.build});

    const cpu = arch.getCpuInfo();
    log.info("CPU: {} cores, vendor: {s}, model: {s}", .{
        smp.getNum(),
        @tagName(cpu.vendor),
        cpu.getName(),
    });

    init(vm);
    init(logger);

    log.info("used memory: {} KiB", .{vm.PageAllocator.getAllocatedPages() * vm.page_size / lib.kb_size});

    init(config);
    preinit(dev);

    init(sys.time);
    sys.time.initPerCpu();

    sched.startup(0, kernelStartupTask) catch |err| {
        log.err("startup failed: {s}", .{@errorName(err)});
        lib.sync.halt();
    };
}

/// Specific task to finish kernel initialization.
/// This task is only for boot cpu.
fn kernelStartupTask() noreturn {
    init(video.terminal);
    smp.initAll();

    logger.initWorker() catch @panic("failed to start logger worker");

    init(vfs);
    init(dev);

    const allocated = @as(usize, vm.PageAllocator.getAllocatedPages()) * vm.page_size;
    log.info("used memory: {} KiB ({} MiB)", .{allocated / lib.kb_size, allocated / lib.mb_size});

    init(sys);

    sched.terminate();
}

inline fn startNonBootCpu() void {
    sys.time.initPerCpu();

    log.info("CPU {} initialized", .{smp.getIdx()});
    sched.getCurrent().start();
}

fn preinit(comptime Module: type) void {
    Module.preinit() catch |err| {
        log.err("Can't pre-initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        lib.sync.halt();

        unreachable;
    };
}

fn init(comptime Module: type) void {
    Module.init() catch |err| {
        log.err("Can't initialize `" ++ @typeName(Module) ++ "` module: {s}", .{@errorName(err)});
        lib.sync.halt();

        unreachable;
    };
}
