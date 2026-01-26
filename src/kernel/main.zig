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
        //.{ .level = .warn, .scope = .@"sys.call.trace" },
        .{ .level = .info, .scope = .@"intr.except" },
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

    smp.initCpu(&main2);
}

/// `main` second half.
/// 
/// Main function is divided into two, because of stack switch.
fn main2() noreturn {
    defer @panic("reached end of the main2");

    log.info("{s} {s}", .{opts.os_name, opts.build});
    {
        const cpu = arch.getCpuInfo();
        log.info("CPUs detected: {}, vendor: {s}, model: {s}", .{
            smp.getNum(),
            @tagName(cpu.vendor),
            cpu.getName(),
        });
    }

    init(vm);
    log.warn("Used memory: {} KiB", .{vm.PageAllocator.getAllocatedPages() * vm.page_size / lib.kb_size});

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
    logger.switchFromEarly();

    smp.initAll();

    //const debug_task = sched.Task.create(
    //    .{ .kernel = .{ .name = "debug_task" } },
    //    @intFromPtr(&debugTask)
    //) catch unreachable;
    //sched.enqueue(debug_task);
    //const other_task =  sched.Task.create(
    //    .{ .kernel = .{ .name = "other_task" } },
    //    @intFromPtr(&debugTask)
    //) catch unreachable;
    //sched.enqueue(other_task);

    init(vfs);
    init(dev);

    init(sys);

    sched.pause();
    unreachable;
}

fn debugTask() noreturn {
    const task = sched.getCurrentTask();

    while (true) {
        log.info("{s}: {} - {}", .{
            task.spec.kernel.name,
            task.stats.time_slice,
            @as(u32, 32) - task.stats.getPriority(),
        });

        const begin = sys.time.getCachedUpTime().sec;
        while (begin == sys.time.getCachedUpTime().sec) {
            sched.yield();
        }
    }

    unreachable;
}

/// Specific task to wait until kernel initialization is done
/// and run userspace after.
fn awaitTask() noreturn {
    sched.pause();
    unreachable;
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
