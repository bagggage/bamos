const std = @import("std");

const sched = @import("../../src/kernel/sched.zig");
const smp = @import("../../src/kernel/smp.zig");
const t = @import("../framework.zig");
const vm = @import("../../src/kernel/vm.zig");
const gpa = vm.gpa;

const Slot = struct {
    ptr: *anyopaque,
    len: usize,
    fill: u8,
};

const RaceContext = struct {
    barrier: t.WorkerBarrier,

    fn init(worker_count: u16) RaceContext {
        return .{ .barrier = .init(worker_count) };
    }
};

const max_wait_yields = 200_000;

pub fn @"small allocation size classes route to expected object allocators"() !void {
    const sizes = [_]usize{
        1,
        gpa.@"test".min_size,
        gpa.@"test".min_size + 1,
        63,
        64,
        gpa.@"test".max_small_size,
    };

    for (sizes) |size| {
        const ptr = try t.expectNotNull(gpa.alloc(size));
        defer gpa.free(ptr);

        try t.expect((@intFromPtr(ptr) % @sizeOf(usize)) == 0);
        try t.expectEqual(expectedSmallPoolIndex(size), try t.expectNotNull(findOwningSmallPool(@intFromPtr(ptr))));
    }
}

pub fn @"huge allocation boundary is page aligned and tracked in tree"() !void {
    const before_pages = vm.PageAllocator.getAllocatedPages();
    const before_nodes = countHugeNodes(gpa.@"test".huge_alloc_tree.root);
    const size = gpa.@"test".max_small_size + 1;
    const ptr = try t.expectNotNull(gpa.alloc(size));
    defer gpa.free(ptr);

    const phys = vm.getPhysLma(ptr);
    const base: u32 = @intCast(phys / vm.page_size);
    const expected_rank = vm.pagesToRank(vm.bytesToPages(size));
    const key = gpa.@"test".HugeFrame{ .base = base, .rank = expected_rank };
    const node = try t.expectNotNull(gpa.@"test".huge_alloc_tree.find(key));

    try t.expectEqual(@as(u8, expected_rank), node.data.rank);
    try t.expect((phys % vm.page_size) == 0);
    try t.expectEqual(before_nodes + 1, countHugeNodes(gpa.@"test".huge_alloc_tree.root));
    try t.expect(vm.PageAllocator.getAllocatedPages() >= before_pages + vm.rankToPages(expected_rank));
}

pub fn @"huge allocations become unavailable under pressure and recover"() !void {
    const before_pages = vm.PageAllocator.getAllocatedPages();
    const before_nodes = countHugeNodes(gpa.@"test".huge_alloc_tree.root);
    const size = vm.rankToBytes(vm.PageAllocator.max_rank - 3) + 1;
    var live: [16]?*anyopaque = .{null} ** 16;
    var used: usize = 0;

    while (gpa.alloc(size)) |ptr| {
        try t.expect(used < live.len);
        live[used] = ptr;
        used += 1;
    }

    try t.expect(used > 0);
    try t.expectNull(gpa.alloc(size));
    try t.expectEqual(before_nodes + used, countHugeNodes(gpa.@"test".huge_alloc_tree.root));

    for (live[0..used]) |slot| {
        gpa.free(slot);
    }

    try t.expectEqual(before_pages, vm.PageAllocator.getAllocatedPages());
    try t.expectEqual(before_nodes, countHugeNodes(gpa.@"test".huge_alloc_tree.root));
}

pub fn @"fuzz mixed alloc and free preserves allocator state"() !void {
    const before = vm.PageAllocator.getAllocatedPages();
    const before_nodes = countHugeNodes(gpa.@"test".huge_alloc_tree.root);
    var rng = t.Fuzzer.init(0x6ab6ab6ab);

    var live: [96]?Slot = .{null} ** 96;
    for (0..64) |i| {
        const should_free = countLiveSlots(&live) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLiveSlotIndex(&live, &rng).?;
            gpa.free(live[idx].?.ptr);
            live[idx] = null;
        } else {
            const size = randomAllocSize(&rng);
            if (gpa.alloc(size)) |ptr| {
                if (firstEmptySlotIndex(&live)) |idx| {
                    fillBytes(ptr, size, @truncate(i));
                    live[idx] = .{ .ptr = ptr, .len = size, .fill = @truncate(i) };
                } else {
                    gpa.free(ptr);
                }
            }
        }

        if ((i & 0xf) == 0) try validateHugeTree();
    }

    for (&live) |*slot| {
        if (slot.*) |live_slot| {
            gpa.free(live_slot.ptr);
            slot.* = null;
        }
    }

    try t.expectEqual(before, vm.PageAllocator.getAllocatedPages());
    try t.expectEqual(before_nodes, countHugeNodes(gpa.@"test".huge_alloc_tree.root));
}

pub fn @"concurrent small alloc and free preserves allocator state"() !void {
    const before_nodes = countHugeNodes(gpa.@"test".huge_alloc_tree.root);
    var ctx = RaceContext.init(t.defaultWorkerCount());

    try t.runRace(RaceContext, "tests-gpa-race", ctx.barrier.worker_count, max_wait_yields, &ctx, &raceWorker);
    try t.expect(vm.PageAllocator.getAllocatedPages() <= vm.PageAllocator.getTotalPages());
    try t.expectEqual(before_nodes, countHugeNodes(gpa.@"test".huge_alloc_tree.root));
}

fn expectedSmallPoolIndex(size: usize) usize {
    if (size <= gpa.@"test".min_size) return 0;
    return std.math.log2_int_ceil(usize, size) - std.math.log2_int(usize, gpa.@"test".min_size);
}

fn findOwningSmallPool(addr: usize) ?usize {
    for (gpa.@"test".oma_pool[0..], 0..) |*oma, idx| {
        if (oma.contains(addr) != null) return idx;
    }

    return null;
}

fn validateHugeTree() !void {
    var stack: [32]?*gpa.@"test".HugeNode = .{null} ** 32;
    var sp: usize = 0;
    var node = gpa.@"test".huge_alloc_tree.root;
    var last_base: ?u32 = null;

    while (node != null or sp > 0) {
        while (node) |curr| {
            try t.expect(sp < stack.len);
            stack[sp] = curr;
            sp += 1;
            node = curr.lhs;
        }

        sp -= 1;
        const curr = stack[sp].?;
        stack[sp] = null;

        if (last_base) |prev| {
            try t.expect(prev < curr.data.base);
        }

        try t.expect(curr.data.rank < vm.PageAllocator.max_rank);
        last_base = curr.data.base;
        node = curr.rhs;
    }
}

fn countHugeNodes(node: ?*gpa.@"test".HugeNode) usize {
    if (node == null) return 0;
    return 1 + countHugeNodes(node.?.lhs) + countHugeNodes(node.?.rhs);
}

fn randomAllocSize(rng: *t.Fuzzer) usize {
    return rng.range(256) + 1;
}

fn verifyFilled(ptr: *anyopaque, len: usize, byte: u8) !void {
    const bytes: [*]u8 = @ptrCast(ptr);
    for (bytes[0..len]) |value| {
        try t.expectEqual(byte, value);
    }
}

fn fillBytes(ptr: *anyopaque, len: usize, byte: u8) void {
    const bytes: [*]u8 = @ptrCast(ptr);
    @memset(bytes[0..len], byte);
}

fn countLiveSlots(slots: []const ?Slot) usize {
    var live: usize = 0;
    for (slots) |slot| {
        if (slot != null) live += 1;
    }
    return live;
}

fn firstEmptySlotIndex(slots: []const ?Slot) ?usize {
    for (slots, 0..) |slot, idx| {
        if (slot == null) return idx;
    }

    return null;
}

fn pickLiveSlotIndex(slots: []const ?Slot, rng: *t.Fuzzer) ?usize {
    const live = countLiveSlots(slots);
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

    var rng = t.Fuzzer.init((@as(u64, smp.getIdx()) << 32) | 0x67fa);
    var live: [32]?Slot = .{null} ** 32;

    for (0..128) |iter| {
        const should_free = countLiveSlots(&live) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLiveSlotIndex(&live, &rng).?;
            const slot = live[idx].?;
            verifyFilled(slot.ptr, slot.len, slot.fill) catch ctx.barrier.fail();
            gpa.free(slot.ptr);
            live[idx] = null;
        } else {
            const size = randomAllocSize(&rng);
            if (gpa.alloc(size)) |ptr| {
                const idx = firstEmptySlotIndex(&live) orelse {
                    gpa.free(ptr);
                    continue;
                };

                const fill = @as(u8, @truncate((iter + idx + smp.getIdx()) & 0xff));
                fillBytes(ptr, size, fill);
                live[idx] = .{ .ptr = ptr, .len = size, .fill = fill };
            }
        }
    }

    for (&live) |*slot| {
        if (slot.*) |live_slot| {
            verifyFilled(live_slot.ptr, live_slot.len, live_slot.fill) catch ctx.barrier.fail();
            gpa.free(live_slot.ptr);
            slot.* = null;
        }
    }

    ctx.barrier.workerDone();
    sched.terminate();
}
