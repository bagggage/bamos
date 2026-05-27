const std = @import("std");

const sched = @import("../../src/kernel/sched.zig");
const t = @import("../framework.zig");
const h = @import("../vfs_harness.zig");
const Harness = h.Harness;
const vfs = @import("../../src/kernel/vfs.zig");

const max_wait_yields = 200_000;

const LookupRaceContext = struct {
    barrier: t.WorkerBarrier,
    parent: *vfs.Dentry,
    name: []const u8,
    expected: usize,
    failures: std.atomic.Value(u16) = .init(0),

    fn init(parent: *vfs.Dentry, name: []const u8, expected: *vfs.Dentry, worker_count: u16) LookupRaceContext {
        return .{
            .barrier = .init(worker_count),
            .parent = parent,
            .name = name,
            .expected = @intFromPtr(expected),
        };
    }
};

const CreateLookupRaceContext = struct {
    barrier: t.WorkerBarrier,
    parent: *vfs.Dentry,
    created: std.atomic.Value(u16) = .init(0),
    next_id: std.atomic.Value(u16) = .init(0),

    fn init(parent: *vfs.Dentry, worker_count: u16) CreateLookupRaceContext {
        return .{
            .barrier = .init(worker_count),
            .parent = parent,
        };
    }
};

const LookupRemoveRaceContext = struct {
    barrier: t.WorkerBarrier,
    parent: *vfs.Dentry,
    target: *vfs.Dentry,
    name: []const u8,
    unlink_errors: std.atomic.Value(u16) = .init(0),
    lookup_failures: std.atomic.Value(u16) = .init(0),
    next_id: std.atomic.Value(u16) = .init(0),

    fn init(parent: *vfs.Dentry, target: *vfs.Dentry, name: []const u8, worker_count: u16) LookupRemoveRaceContext {
        return .{
            .barrier = .init(worker_count),
            .parent = parent,
            .target = target,
            .name = name,
        };
    }
};

pub fn @"create lookup and iterate preserve child metadata"() !void {
    var harness = try Harness.init(.{});
    const dir = try harness.root.makeDirectory("alpha", .{ .uid = 10, .gid = 20 });
    const file = try dir.createFile("notes", .{ .perm = vfs.Permissions.makeInt(.rw, .r, .none) });

    try t.expectEqual(dir, try harness.requireDirectory("/alpha"));
    try t.expectEqual(file, try harness.requireFile("/alpha/notes"));

    var buffer: [4]h.IterEntry = undefined;
    const entries = try h.collectEntries(dir, &buffer);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expect(std.mem.eql(u8, "notes", entries[0].name));
    try t.expectEqual(vfs.Inode.Type.regular_file, entries[0].@"type");
}

pub fn @"path formatting supports long names and relative roots"() !void {
    var harness = try Harness.init(.{});
    const long_name = "abcdefghijklmnopqrstuvwxyz0123456789-long";
    const parent = try harness.root.makeDirectory("top", .{});
    const child = try parent.makeDirectory(long_name, .{});

    var abs_buf: [128]u8 = undefined;
    const abs = try std.fmt.bufPrint(&abs_buf, "{f}", .{child.relativePath(harness.root)});
    try t.expect(std.mem.eql(u8, "/top/" ++ long_name, abs));

    var rel_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, "{f}", .{child.relativePath(parent)});
    try t.expect(std.mem.eql(u8, "/" ++ long_name, rel));
}

pub fn @"touch updates access and modify timestamps"() !void {
    const sys = @import("../../src/kernel/sys.zig");

    var harness = try Harness.init(.{});
    const file = try harness.root.createFile("time", .{});
    const access: sys.time.Time = .{ .sec = 111 };
    const modify: sys.time.Time = .{ .sec = 222 };

    try file.touch(access, modify);
    try t.expectEqual(@as(u64, 111), file.inode.access_time);
    try t.expectEqual(@as(u64, 222), file.inode.modify_time);
}

pub fn @"remove and unlink are still rejected"() !void {
    var harness = try Harness.init(.{});
    const file = try harness.root.createFile("gone", .{});

    try t.expectError(error.BadOperation, file.remove());
    try t.expectError(error.BadOperation, file.unlink());
}

pub fn @"concurrent lookup of cached child returns same dentry"() !void {
    var harness = try Harness.init(.{});
    const dir = try harness.root.makeDirectory("lookup", .{});
    const child = try dir.createFile("shared", .{});
    var ctx = LookupRaceContext.init(dir, "shared", child, t.defaultWorkerCount());

    try t.runRace(LookupRaceContext, "tests-vfs-dentry-lookup", ctx.barrier.worker_count, max_wait_yields, &ctx, &lookupRaceWorker);
    try t.expectEqual(@as(u16, 0), ctx.failures.load(.acquire));
}

pub fn @"concurrent createFile and lookup with distinct names succeeds"() !void {
    var harness = try Harness.init(.{});
    const dir = try harness.root.makeDirectory("create-race", .{});
    var ctx = CreateLookupRaceContext.init(dir, t.defaultWorkerCount());

    try t.runRace(CreateLookupRaceContext, "tests-vfs-dentry-create-lookup", ctx.barrier.worker_count, max_wait_yields, &ctx, &createLookupRaceWorker);
    try t.expectEqual(ctx.barrier.worker_count, ctx.created.load(.acquire));

    var entries_buf: [16]h.IterEntry = undefined;
    const entries = try h.collectEntries(dir, &entries_buf);
    try t.expectEqual(@as(usize, ctx.barrier.worker_count), entries.len);
}

pub fn @"concurrent lookup and unlink preserve current stub behavior"() !void {
    var harness = try Harness.init(.{});
    const dir = try harness.root.makeDirectory("unlink-race", .{});
    const file = try dir.createFile("victim", .{});
    var ctx = LookupRemoveRaceContext.init(dir, file, "victim", t.defaultWorkerCount());

    try t.runRace(LookupRemoveRaceContext, "tests-vfs-dentry-lookup-unlink", ctx.barrier.worker_count, max_wait_yields, &ctx, &lookupRemoveRaceWorker);
    try t.expect(ctx.unlink_errors.load(.acquire) > 0);
    try t.expectEqual(@as(u16, 0), ctx.lookup_failures.load(.acquire));
    try t.expectEqual(file, try harness.requireFile("/unlink-race/victim"));
}

fn lookupRaceWorker(arg: usize) noreturn {
    const ctx: *LookupRaceContext = @ptrFromInt(arg);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    for (0..64) |_| {
        const dent = ctx.parent.lookup(ctx.name) orelse {
            _ = ctx.failures.fetchAdd(1, .acq_rel);
            break;
        };
        if (@intFromPtr(dent) != ctx.expected) {
            _ = ctx.failures.fetchAdd(1, .acq_rel);
        }
        dent.deref();
        sched.yield();
    }

    ctx.barrier.workerDone();
    sched.terminate();
}

fn createLookupRaceWorker(arg: usize) noreturn {
    const ctx: *CreateLookupRaceContext = @ptrFromInt(arg);
    const worker_id = ctx.next_id.fetchAdd(1, .acq_rel);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    var name_buf: [24]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "child-{}", .{worker_id}) catch unreachable;
    const dent = ctx.parent.createFile(name, .{}) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };
    _ = ctx.created.fetchAdd(1, .acq_rel);

    const looked_up = ctx.parent.lookup(name) orelse {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    if (looked_up != dent) ctx.barrier.fail();
    looked_up.deref();

    ctx.barrier.workerDone();
    sched.terminate();
}

fn lookupRemoveRaceWorker(arg: usize) noreturn {
    const ctx: *LookupRemoveRaceContext = @ptrFromInt(arg);
    const worker_id = ctx.next_id.fetchAdd(1, .acq_rel);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    for (0..32) |_| {
        if ((worker_id & 1) == 0) {
            if (ctx.parent.lookup(ctx.name)) |dent| {
                if (dent != ctx.target) _ = ctx.lookup_failures.fetchAdd(1, .acq_rel);
                dent.deref();
            } else {
                _ = ctx.lookup_failures.fetchAdd(1, .acq_rel);
            }
        } else {
            ctx.target.unlink() catch |err| {
                if (err == error.BadOperation) {
                    _ = ctx.unlink_errors.fetchAdd(1, .acq_rel);
                } else {
                    ctx.barrier.fail();
                }
            };
        }
        sched.yield();
    }

    ctx.barrier.workerDone();
    sched.terminate();
}
