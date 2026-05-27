//! Kernel tests runner

const builtin = @import("builtin");
const std = @import("std");
const unit = @import("unit/root.zig");

const log = std.log.scoped(.tests);

const Stats = struct {
    tests: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

/// Entry point for kernel tests.
/// This function is called from `sys.init` after kernel
/// initialization is done.
pub fn start() noreturn {
    var stats: Stats = .{};
    var discovered = false;

    inline for (@typeInfo(unit).@"struct".decls) |decl| {
        const suite = @field(unit, decl.name);
        if (@TypeOf(suite) != type) continue;
        if (@typeInfo(suite) != .@"struct") continue;

        discovered = true;
        runSuite(decl.name, suite, &stats);
    }

    if (!discovered or stats.tests == 0) {
        log.warn("No tests were discovered.", .{});
        exit();
    }

    if (stats.failed == 0) {
        log.info("All {} tests passed.", .{stats.passed});
    } else {
        log.err(
            "{} of {} tests passed, {} failed.",
            .{ stats.passed, stats.tests, stats.failed },
        );
    }

    if (stats.skipped > 0) {
        log.warn("{} declarations were skipped.", .{stats.skipped});
    }

    exit();
}

fn runSuite(comptime suite_name: []const u8, comptime Suite: type, stats: *Stats) void {
    const total = countTests(Suite);
    log.info("\nRunning test: {s}.zig", .{suite_name});

    if (total == 0) {
        log.warn("No runnable tests in {s}.zig.", .{suite_name});
        return;
    }

    var idx: usize = 0;
    inline for (@typeInfo(Suite).@"struct".decls) |decl| {
        const DeclType = @TypeOf(@field(Suite, decl.name));
        if (@typeInfo(DeclType) != .@"fn") continue;

        if (isTestFn(DeclType)) {
            idx += 1;
            runTest(Suite, suite_name, decl.name, idx, total, stats);
        } else {
            stats.skipped += 1;
        }
    }
}

fn runTest(
    comptime Suite: type,
    comptime suite_name: []const u8,
    comptime test_name: []const u8,
    idx: usize,
    total: usize,
    stats: *Stats,
) void {
    const test_fn = @field(Suite, test_name);
    stats.tests += 1;

    if (invokeTest(test_fn)) |err| {
        stats.failed += 1;
        log.err(
            "{}/{} {s}.{s}...FAIL ({s})",
            .{ idx, total, suite_name, test_name, @errorName(err) },
        );
        return;
    }

    stats.passed += 1;
    log.info("{}/{} {s}.{s}...OK", .{ idx, total, suite_name, test_name });
}

fn isTestFn(comptime FnType: type) bool {
    const type_info = @typeInfo(FnType);
    if (type_info != .@"fn") return false;

    const fn_info = type_info.@"fn";
    if (fn_info.is_var_args or fn_info.params.len != 0) return false;

    const Ret = fn_info.return_type orelse return false;
    return switch (@typeInfo(Ret)) {
        .void => true,
        .error_union => |error_union| error_union.payload == void,
        else => false,
    };
}

fn invokeTest(test_fn: anytype) ?anyerror {
    const Ret = @typeInfo(@TypeOf(test_fn)).@"fn".return_type.?;

    switch (@typeInfo(Ret)) {
        .void => {
            @call(.auto, test_fn, .{});
            return null;
        },
        .error_union => {
            @call(.auto, test_fn, .{}) catch |err| return err;
            return null;
        },
        else => unreachable,
    }
}

fn countTests(comptime Suite: type) usize {
    var total: usize = 0;

    inline for (@typeInfo(Suite).@"struct".decls) |decl| {
        const DeclType = @TypeOf(@field(Suite, decl.name));
        if (@typeInfo(DeclType) != .@"fn") continue;
        if (isTestFn(DeclType)) total += 1;
    }

    return total;
}

/// Shutdown QEMU machine.
fn exit() noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => outw(0x604, 0x2000),
        else => @compileError("Unsupported architecture"),
    }

    unreachable;
}

inline fn outw(port: u16, word: u16) void {
    asm volatile ("outw %[d],%[p]"
        :
        : [d] "{ax}" (word),
          [p] "{dx}" (port),
    );
}
