const std = @import("std");

const sched = @import("../../src/kernel/sched.zig");
const smp = @import("../../src/kernel/smp.zig");
const t = @import("../framework.zig");
const Harness = @import("../vfs_harness.zig").Harness;
const vfs = @import("../../src/kernel/vfs.zig");

const max_wait_yields = 200_000;

const WriteRaceContext = struct {
    barrier: t.WorkerBarrier,
    file: *vfs.File,
    stride: usize,
    chunk_len: usize,

    fn init(file: *vfs.File, worker_count: u16, stride: usize, chunk_len: usize) WriteRaceContext {
        return .{
            .barrier = .init(worker_count),
            .file = file,
            .stride = stride,
            .chunk_len = chunk_len,
        };
    }
};

const OpenCloseRaceContext = struct {
    barrier: t.WorkerBarrier,
    dentry: *vfs.Dentry,
    next_id: std.atomic.Value(u16) = .init(0),

    fn init(dentry: *vfs.Dentry, worker_count: u16) OpenCloseRaceContext {
        return .{
            .barrier = .init(worker_count),
            .dentry = dentry,
        };
    }
};

pub fn @"read write and positional io update offsets as expected"() !void {
    var harness = try Harness.init(.{});
    const dentry = try harness.root.createFile("data", .{});
    const file = try dentry.open(.rw);
    defer file.deref();

    try t.expectEqual(@as(usize, 5), try file.write("hello"));
    try t.expectEqual(@as(usize, 5), file.offset);

    var prefix: [2]u8 = undefined;
    try t.expectEqual(@as(usize, 2), try file.readAt(0, &prefix));
    try t.expect(std.mem.eql(u8, "he", &prefix));
    try t.expectEqual(@as(usize, 5), file.offset);

    try t.expectEqual(@as(usize, 2), try file.writeAt(1, "XY"));
    try t.expectEqual(@as(usize, 5), file.offset);

    file.offset = 0;
    var full: [5]u8 = undefined;
    try file.readAll(&full);
    try t.expect(std.mem.eql(u8, "hXYlo", &full));
    try t.expectEqual(@as(usize, 5), file.offset);
}

pub fn @"read past eof and short readAll report correctly"() !void {
    var harness = try Harness.init(.{});
    const dentry = try harness.root.createFile("short", .{});
    const file = try dentry.open(.rw);
    defer file.deref();

    _ = try file.write("abc");

    var tail: [4]u8 = .{0} ** 4;
    try t.expectEqual(@as(usize, 0), try file.readAt(10, &tail));
    try t.expectError(error.IoFailed, file.readAll(&tail));
}

pub fn @"directory open rejects regular file io but still polls"() !void {
    var harness = try Harness.init(.{});
    const file = try harness.root.open(.rw);
    defer file.deref();

    var buf: [8]u8 = undefined;
    try t.expectError(error.NotRegularFile, file.read(&buf));

    const poll = try file.poll();
    try t.expect(poll.read_avail);
    try t.expect(poll.may_write);
}

pub fn @"validateAccess rejects permissions outside open mode"() !void {
    var harness = try Harness.init(.{});
    const dentry = try harness.root.createFile("perm", .{});
    const file = try dentry.open(.r);
    defer file.deref();

    try file.validateAccess(.r);
    try t.expectError(error.NoAccess, file.validateAccess(.w));
}

pub fn @"concurrent writeAt to disjoint file ranges preserves data"() !void {
    var harness = try Harness.init(.{});
    const dentry = try harness.root.createFile("race", .{});
    const file = try dentry.open(.rw);
    defer file.deref();

    const workers = t.defaultWorkerCount();
    const chunk_len = 64;
    const stride = chunk_len * workers;
    var ctx = WriteRaceContext.init(file, workers, stride, chunk_len);

    try t.runRace(WriteRaceContext, "tests-vfs-file-write", workers, max_wait_yields, &ctx, &writeRaceWorker);

    var result: [512]u8 = .{0} ** 512;
    const expected_len: usize = workers * chunk_len;
    try t.expectEqual(expected_len, try file.readAt(0, result[0..expected_len]));

    for (0..workers) |idx| {
        const expected = @as(u8, @truncate('A' + idx));
        for (result[idx * chunk_len .. (idx + 1) * chunk_len]) |byte| {
            try t.expectEqual(expected, byte);
        }
    }
}

pub fn @"concurrent open and close preserves file usability"() !void {
    var harness = try Harness.init(.{});
    const dentry = try harness.root.createFile("open-close", .{});
    const seed = try dentry.open(.rw);
    defer seed.deref();
    _ = try seed.write("seed");

    var ctx = OpenCloseRaceContext.init(dentry, t.defaultWorkerCount());
    try t.runRace(OpenCloseRaceContext, "tests-vfs-file-open-close", ctx.barrier.worker_count, max_wait_yields, &ctx, &openCloseRaceWorker);

    const verify = try dentry.open(.r);
    defer verify.deref();

    var buf: [4]u8 = undefined;
    try verify.readAll(&buf);
    try t.expect(std.mem.eql(u8, "seed", &buf));
}

fn writeRaceWorker(arg: usize) noreturn {
    const ctx: *WriteRaceContext = @ptrFromInt(arg);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    const idx = smp.getIdx() % ctx.barrier.worker_count;
    var payload: [64]u8 = undefined;
    @memset(payload[0..ctx.chunk_len], @as(u8, @truncate('A' + idx)));

    _ = ctx.file.writeAt(idx * ctx.chunk_len, payload[0..ctx.chunk_len]) catch {
        ctx.barrier.fail();
    };

    ctx.barrier.workerDone();
    sched.terminate();
}

fn openCloseRaceWorker(arg: usize) noreturn {
    const ctx: *OpenCloseRaceContext = @ptrFromInt(arg);
    _ = ctx.next_id.fetchAdd(1, .acq_rel);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    const file = ctx.dentry.open(.r) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    var buf: [4]u8 = undefined;
    _ = file.readAt(0, &buf) catch ctx.barrier.fail();
    file.deref();

    ctx.barrier.workerDone();
    sched.terminate();
}
