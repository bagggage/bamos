//! # Executor

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const logger = std.log.scoped(.executor);

const arch = @import("../utils.zig").arch;
const dev = @import("../dev.zig");
const scheduler = @import("scheduler.zig");
const smp = @import("../smp.zig");
const utils = @import("../utils.zig");

pub fn init() !void {
    
}

pub fn begin() noreturn {
    scheduler.schedule();

    const task = scheduler.next() orelse {
        logger.warn("No tasks to begin with. Halting the kernel...", .{});
        utils.halt();
    };

    smp.getLocalData().current_task = task;    
    task.asUserTask().thread.context.jumpTo();
}
