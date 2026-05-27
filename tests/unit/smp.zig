const std = @import("std");

const smp = @import("../../src/kernel/smp.zig");
const t = @import("../framework.zig");

const max_wait_yields = 200_000;

const CpuProbeContext = struct {
    barrier: t.WorkerBarrier,
    seen_mask: std.atomic.Value(u64) = .init(0),

    fn init(worker_count: u16) CpuProbeContext {
        return .{ .barrier = .init(worker_count) };
    }
};

pub fn @"cpu local data is initialized for every cpu"() !void {
    try t.expect(smp.getNum() > 0);
    try t.expectEqual(@as(u16, 0), smp.getIdx());

    for (0..smp.getNum()) |idx| {
        const cpu_idx: u16 = @intCast(idx);
        const data = smp.getCpuData(cpu_idx);
        try t.expectEqual(cpu_idx, data.idx);
    }
}

pub fn @"workers can run on every cpu"() !void {
    var ctx = CpuProbeContext.init(smp.getNum());
    try t.runRace(CpuProbeContext, "tests-cpu-probe", smp.getNum(), max_wait_yields, &ctx, &cpuProbeWorker);

    const expected_mask = if (smp.getNum() >= 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(smp.getNum())) - 1;
    try t.expectEqual(expected_mask, ctx.seen_mask.load(.acquire));
}

fn cpuProbeWorker(arg: usize) noreturn {
    const ctx: *CpuProbeContext = @ptrFromInt(arg);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        @import("../../src/kernel/sched.zig").terminate();
    };

    const cpu_idx = smp.getIdx();
    _ = ctx.seen_mask.fetchOr(@as(u64, 1) << @intCast(cpu_idx), .acq_rel);
    ctx.barrier.workerDone();
    @import("../../src/kernel/sched.zig").terminate();
}
