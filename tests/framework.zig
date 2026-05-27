const std = @import("std");
const lib = @import("../src/kernel/lib.zig");
const sched = @import("../src/kernel/sched.zig");
const smp = @import("../src/kernel/smp.zig");

pub const TestError = error{
    UnexpectedResult,
    UnexpectedError,
    ValueMismatch,
    UnexpectedNull,
};

pub fn expect(ok: bool) TestError!void {
    if (!ok) return error.UnexpectedResult;
}

pub fn expectEqual(expected: anytype, actual: @TypeOf(expected)) TestError!void {
    if (actual != expected) return error.ValueMismatch;
}

pub fn expectNotEqual(unexpected: anytype, actual: @TypeOf(unexpected)) TestError!void {
    if (actual == unexpected) return error.UnexpectedResult;
}

pub fn expectNull(value: anytype) TestError!void {
    if (value != null) return error.UnexpectedResult;
}

pub fn expectNotNull(value: anytype) TestError!@TypeOf(value.?) {
    return value orelse error.UnexpectedNull;
}

pub fn expectError(expected: anyerror, actual: anytype) TestError!void {
    _ = actual catch |err| {
        if (err == expected) return;
        return error.UnexpectedError;
    };

    return error.UnexpectedResult;
}

pub fn spinUntil(comptime predicate: fn () bool, max_yields: usize) TestError!void {
    var yields: usize = 0;
    while (!predicate()) : (yields += 1) {
        if (yields >= max_yields) return error.UnexpectedResult;
        sched.yield();
    }
}

pub fn waitForAtomic(comptime T: type, value: *std.atomic.Value(T), expected: T, max_yields: usize) TestError!void {
    var yields: usize = 0;
    while (value.load(.acquire) != expected) : (yields += 1) {
        if (yields >= max_yields) return error.UnexpectedResult;
        sched.yield();
    }
}

pub fn yieldTimes(times: usize) void {
    for (0..times) |_| sched.yield();
}

pub const WorkerBarrier = struct {
    worker_count: u16,
    ready: std.atomic.Value(u16) = .init(0),
    start: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u16) = .init(0),
    failures: std.atomic.Value(u16) = .init(0),

    pub fn init(worker_count: u16) WorkerBarrier {
        return .{ .worker_count = worker_count };
    }

    pub fn workerReady(self: *WorkerBarrier) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
    }

    pub fn waitForStart(self: *WorkerBarrier, max_yields: usize) TestError!void {
        try waitForAtomic(bool, &self.start, true, max_yields);
    }

    pub fn workerDone(self: *WorkerBarrier) void {
        _ = self.done.fetchAdd(1, .acq_rel);
    }

    pub fn fail(self: *WorkerBarrier) void {
        _ = self.failures.fetchAdd(1, .acq_rel);
    }

    pub fn startAll(self: *WorkerBarrier, max_yields: usize) TestError!void {
        try waitForAtomic(u16, &self.ready, self.worker_count, max_yields);
        self.start.store(true, .release);
    }

    pub fn waitAllDone(self: *WorkerBarrier, max_yields: usize) TestError!void {
        try waitForAtomic(u16, &self.done, self.worker_count, max_yields);
    }
};

pub fn spawnWorkers(
    comptime Context: type,
    name: []const u8,
    worker_count: u16,
    ctx: *Context,
    worker_fn: *const fn (usize) noreturn,
) !void {
    for (0..worker_count) |idx| {
        const cpu_idx: u16 = @intCast(idx % smp.getNum());
        const task = try sched.Task.createWorker(name, worker_fn, .fromPtr(ctx));
        sched.getScheduler(cpu_idx).enqueueTask(task);
    }
}

pub fn runRace(
    comptime Context: type,
    name: []const u8,
    worker_count: u16,
    max_yields: usize,
    ctx: *Context,
    worker_fn: *const fn (usize) noreturn,
) !void {
    try spawnWorkers(Context, name, worker_count, ctx, worker_fn);
    try ctx.barrier.startAll(max_yields);
    try ctx.barrier.waitAllDone(max_yields);
    yieldTimes(512);
    try expectEqual(@as(u16, 0), ctx.barrier.failures.load(.acquire));
}

pub fn defaultWorkerCount() u16 {
    return @max(smp.getNum(), 2);
}

pub const Fuzzer = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Fuzzer {
        return .{
            .prng = std.Random.DefaultPrng.init(
                if (seed == 0) 0x9e3779b97f4a7c15 else seed,
            ),
        };
    }

    pub fn next(self: *Fuzzer) u64 {
        return self.prng.next();
    }

    pub fn int(self: *Fuzzer, comptime T: type) T {
        return self.prng.random().int(T);
    }

    pub fn range(self: *Fuzzer, limit: usize) usize {
        std.debug.assert(limit > 0);
        return self.prng.random().uintLessThan(usize, limit);
    }

    pub fn coin(self: *Fuzzer) bool {
        return self.prng.random().boolean();
    }
};
