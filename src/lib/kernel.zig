const std = @import("std");
const builtin = @import("builtin");

pub const arch = lib.arch;
pub const dev = @import("dev.zig");
pub const lib = @import("lib.zig");
pub const logger = @import("logger.zig");
pub const sched = @import("sched.zig");
pub const smp = @import("smp.zig");
pub const sys = @import("sys.zig");
pub const vfs = @import("vfs.zig");
pub const video = @import("video.zig");
pub const vm = @import("vm.zig");

pub const std_options = std.Options {
    .logFn = logger.defaultLog,
    .log_level = switch (builtin.mode) {
        .Debug,
        .ReleaseSafe => .debug,
        .ReleaseSmall,
        .ReleaseFast => .info
    },
};
