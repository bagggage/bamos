const std = @import("std");

const arch = utils.arch;
const boot = @import("boot.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

pub const panic = @import("panic.zig").panic;

export fn main() noreturn {
    defer @panic("reached end of the main");

    arch.preinit();

    log.info("Kernel startup at CPU: {}", .{arch.getCpuIdx()});
    log.info("CPUs detected: {}", .{boot.getCpusNum()});

    vm.init() catch |err| {
        log.err("Can't initialize VM module: {}", .{err});
    };
}
