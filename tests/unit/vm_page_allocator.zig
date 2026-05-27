const std = @import("std");

const t = @import("../framework.zig");
const sched = @import("../../src/kernel/sched.zig");
const smp = @import("../../src/kernel/smp.zig");
const vm = @import("../../src/kernel/vm.zig");
const PageAllocator = vm.PageAllocator;

const Slot = struct {
    base: usize,
    rank: u8,
};

const RaceContext = struct {
    barrier: t.WorkerBarrier,

    fn init(worker_count: u16) RaceContext {
        return .{ .barrier = .init(worker_count) };
    }
};

const max_wait_yields = 200_000;

pub fn @"counters are sane after bootstrap"() !void {
    try t.expect(PageAllocator.isInitialized());
    try t.expect(PageAllocator.getTotalPages() > 0);
    try t.expect(PageAllocator.getAllocatedPages() > 0 and
        PageAllocator.getAllocatedPages() <= PageAllocator.getTotalPages());
    try validateAllocatorState();
}

pub fn @"alloc rejects out of range rank"() !void {
    try t.expectNull(PageAllocator.alloc(PageAllocator.max_rank));
}

pub fn @"large blocks become unavailable under pressure and recover"() !void {
    const rank = try t.expectNotNull(findAvailableLargeRank());
    const before = PageAllocator.getAllocatedPages();
    var blocks: [64]?usize = .{null} ** 64;
    var used: usize = 0;

    while (PageAllocator.alloc(rank)) |base| {
        try t.expect(used < blocks.len);
        try t.expect((base % vm.rankToBytes(rank)) == 0);

        blocks[used] = base;
        used += 1;
    }

    try t.expect(used > 0);
    try t.expectNull(PageAllocator.alloc(rank));
    try validateAllocatorState();

    for (blocks[0..used]) |*slot| {
        PageAllocator.free(slot.*.?, rank);
        slot.* = null;
    }

    try t.expectEqual(before, PageAllocator.getAllocatedPages());
    try validateAllocatorState();
}

pub fn @"alloc and free preserve invariants"() !void {
    const before = PageAllocator.getAllocatedPages();

    const page = try t.expectNotNull(PageAllocator.alloc(0));
    const block = try t.expectNotNull(PageAllocator.alloc(3));

    try t.expect((page % vm.page_size) == 0);
    try t.expect((block % vm.rankToBytes(3)) == 0);
    var live = [_]?Slot{
        .{ .base = page, .rank = 0 },
        .{ .base = block, .rank = 3 },
    };
    try validateTracking(Slot, before, &live);

    PageAllocator.free(block, 3);
    PageAllocator.free(page, 0);

    try t.expectEqual(before, PageAllocator.getAllocatedPages());
    try t.expect(PageAllocator.getAllocatedPages() <= PageAllocator.getTotalPages());
    try validateAllocatorState();
}

pub fn @"fuzz alloc and free preserves buddy invariants"() !void {
    const before = PageAllocator.getAllocatedPages();
    var rng = t.Fuzzer.init(0xfeeda110c);

    var slots: [96]?Slot = .{null} ** 96;

    for (0..256) |i| {
        const should_free = countLive(Slot, &slots) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLiveIndex(Slot, &slots, &rng).?;
            const slot = slots[idx].?;
            PageAllocator.free(slot.base, slot.rank);
            slots[idx] = null;
        } else {
            const rank: u8 = @intCast(rng.range(6));
            if (PageAllocator.alloc(rank)) |base| {
                if (firstEmptyIndex(Slot, &slots)) |idx| {
                    slots[idx] = .{ .base = base, .rank = rank };
                } else {
                    PageAllocator.free(base, rank);
                }
            }
        }

        if ((i & 0xf) == 0) try validateTracking(Slot, before, &slots);
    }

    for (&slots) |*slot| {
        if (slot.*) |live| {
            PageAllocator.free(live.base, live.rank);
            slot.* = null;
        }
    }

    try t.expectEqual(before, PageAllocator.getAllocatedPages());
    try t.expect(PageAllocator.getAllocatedPages() <= PageAllocator.getTotalPages());
    try validateAllocatorState();
}

pub fn @"concurrent alloc free preserves invariants"() !void {
    var ctx = RaceContext.init(t.defaultWorkerCount());
    try t.runRace(RaceContext, "tests-page-race", ctx.barrier.worker_count, max_wait_yields, &ctx, &raceWorker);
    try t.expect(PageAllocator.getAllocatedPages() <= PageAllocator.getTotalPages());
    try validateAllocatorState();
}

fn validateAllocatorState() !void {
    var free_pages: usize = 0;

    for (PageAllocator.@"test".free_areas[0..], 0..) |*area, rank_idx| {
        const rank: u8 = @intCast(rank_idx);
        var node = area.list.first;

        while (node) |curr| : (node = curr.next) {
            const phys = PageAllocator.@"test".getPageNodePhys(curr);

            try t.expect((phys % vm.rankToBytes(rank)) == 0);
            free_pages += vm.rankToPages(rank);
        }
    }

    try t.expectEqual(PageAllocator.getTotalPages(), free_pages + PageAllocator.getAllocatedPages());
}

fn findAvailableLargeRank() ?u8 {
    var rank: u8 = PageAllocator.max_rank - 1;
    while (rank > 8) : (rank -= 1) {
        if (PageAllocator.alloc(rank)) |base| {
            PageAllocator.free(base, rank);
            return rank;
        }
    }

    return null;
}

fn validateTracking(comptime T: type, before: u32, slots: []const ?T) !void {
    var live_pages: u32 = 0;
    try validateLocalTracking(T, slots);

    for (slots) |slot| {
        const live = slot orelse continue;
        live_pages += vm.rankToPages(live.rank);
    }

    try t.expectEqual(before + live_pages, PageAllocator.getAllocatedPages());
}

fn validateLocalTracking(comptime T: type, slots: []const ?T) !void {
    for (slots, 0..) |slot, idx| {
        const live = slot orelse continue;
        const pages = vm.rankToPages(live.rank);

        try t.expect((live.base % vm.rankToBytes(live.rank)) == 0);
        try t.expect((live.base % vm.page_size) == 0);

        for (slots[idx + 1..]) |other_slot| {
            const other = other_slot orelse continue;
            const other_pages = vm.rankToPages(other.rank);
            const base_a: u32 = @intCast(live.base / vm.page_size);
            const base_b: u32 = @intCast(other.base / vm.page_size);
            try t.expect(base_a + pages <= base_b or base_b + other_pages <= base_a);
        }
    }
}

fn countLive(comptime T: type, slots: []const ?T) usize {
    var live: usize = 0;
    for (slots) |slot| {
        if (slot != null) live += 1;
    }
    return live;
}

fn firstEmptyIndex(comptime T: type, slots: []const ?T) ?usize {
    for (slots, 0..) |slot, idx| {
        if (slot == null) return idx;
    }

    return null;
}

fn pickLiveIndex(comptime T: type, slots: []const ?T, rng: *t.Fuzzer) ?usize {
    const live = countLive(T, slots);
    if (live == 0) return null;

    var nth = rng.range(live);
    for (slots, 0..) |slot, idx| {
        if (slot == null) continue;
        if (nth == 0) return idx;
        nth -= 1;
    }

    return null;
}

fn raceWorker(arg: usize) noreturn {
    const ctx: *RaceContext = @ptrFromInt(arg);
    ctx.barrier.workerReady();
    ctx.barrier.waitForStart(max_wait_yields) catch {
        ctx.barrier.fail();
        ctx.barrier.workerDone();
        sched.terminate();
    };

    var rng = t.Fuzzer.init(@as(u64, smp.getIdx()) + 0xfeedcafe);
    var slots: [32]?Slot = .{null} ** 32;

    for (0..96) |_| {
        const should_free = countLive(Slot, &slots) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLiveIndex(Slot, &slots, &rng).?;
            const slot = slots[idx].?;
            PageAllocator.free(slot.base, slot.rank);
            slots[idx] = null;
        } else {
            const rank: u8 = @intCast(rng.range(5));
            if (PageAllocator.alloc(rank)) |base| {
                if (firstEmptyIndex(Slot, &slots)) |idx| {
                    slots[idx] = .{ .base = base, .rank = rank };
                } else {
                    PageAllocator.free(base, rank);
                }
            }
        }
    }

    validateLocalTracking(Slot, &slots) catch ctx.barrier.fail();

    for (&slots) |*slot| {
        if (slot.*) |live| {
            PageAllocator.free(live.base, live.rank);
            slot.* = null;
        }
    }

    ctx.barrier.workerDone();
    sched.terminate();
}
