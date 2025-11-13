// @noexport

//! # Kernel entry point

// Copyright (C) 2024-2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = utils.arch;
const boot = @import("boot.zig");
const config = utils.config;
const dev = @import("dev.zig");
const logger = @import("logger.zig");
const log = std.log;
const sched = @import("sched.zig");
const smp = @import("smp.zig");
const sys = @import("sys.zig");
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

    smp.initCpu(&main2);
}

/// `main` second half.
/// 
/// Main function is divided into two, because of stack switch.
fn main2() noreturn {
    defer @panic("reached end of the main2");

    {
        const cpu = arch.getCpuInfo();
        log.info("CPUs detected: {}, vendor: {s}, model: {s}", .{
            smp.getNum(),
            @tagName(cpu.vendor),
            cpu.getName(),
        });
    }

    init(vm);
    log.warn("Used memory: {} KiB", .{vm.PageAllocator.getAllocatedPages() * vm.page_size / utils.kb_size});

    init(config);

    preinit(dev);

    init(sys.time);
    init(sched);

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

    //const fake_task = sched.newKernelTask("fake", fakeTask).?;
    //sched.enqueue(fake_task);
    //const other_task = sched.newKernelTask("other_task", fakeTask).?;
    //sched.enqueue(other_task);

    init(vfs);
    init(dev);

    init(sys);

    sched.pause();
    unreachable;
}

fn fakeTask() noreturn {
    const scheduler: *volatile sched.Scheduler = sched.getCurrent();

    while (true) {
        log.debug("{s}: {} - {}", .{
            scheduler.current_task.asKernelTask().name,
            scheduler.current_task.common.time_slice,
            @as(u32, 32) - scheduler.current_task.common.getPriority(),
        });

        for (0..10) |_| sched.yield();
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
