const std = @import("std");

const sched = @import("../../src/kernel/sched.zig");
const smp = @import("../../src/kernel/smp.zig");
const t = @import("../framework.zig");
const vm = @import("../../src/kernel/vm.zig");
const LargeSlot = [512]u8;

const TestObj = extern struct {
    a: usize,
    b: usize,
};

const RaceContext = struct {
    barrier: t.WorkerBarrier,
    allocator: vm.ObjectAllocator,

    fn init(worker_count: u16) RaceContext {
        return .{
            .barrier = .init(worker_count),
            .allocator = vm.ObjectAllocator.initCapacity(@sizeOf([2]usize), 32),
        };
    }
};

const max_wait_yields = 200_000;

pub fn @"alloc and free reuse freed entry"() !void {
    var oma = vm.ObjectAllocator.initCapacity(@sizeOf(TestObj), 8);
    defer oma.deinit();

    const first = try t.expectNotNull(oma.alloc(TestObj));
    const second = try t.expectNotNull(oma.alloc(TestObj));
    const third = try t.expectNotNull(oma.alloc(TestObj));

    try validateState(&oma);

    oma.free(second);
    const reused = try t.expectNotNull(oma.alloc(TestObj));

    try t.expectEqual(@intFromPtr(second), @intFromPtr(reused));
    try t.expect(@intFromPtr(first) != @intFromPtr(third));
    try validateState(&oma);

    oma.free(first);
    oma.free(third);
    oma.free(reused);

    try t.expect(oma.arenas.first.load(.acquire) == null);
}

pub fn @"single arena exhausts and returns null until freed"() !void {
    const before = vm.PageAllocator.getAllocatedPages();
    var oma = try initRawAllocator(@sizeOf(LargeSlot), 1);
    defer oma.deinit();
    const arena = vm.ObjectAllocator.Arena.fromNode(oma.arenas.first.load(.acquire).?);

    var live: [8]?*LargeSlot = .{null} ** 8;
    live[0] = @ptrFromInt(arena.allocFirst(oma.obj_size));
    for (1..oma.arena_capacity) |idx| {
        live[idx] = @ptrFromInt(try t.expectNotNull(arena.alloc(oma.obj_size, oma.arena_capacity)));
    }

    try t.expectEqual(@as(usize, 1), countArenas(&oma));
    try t.expectNull(arena.alloc(oma.obj_size, oma.arena_capacity));

    const freed = live[3].?;
    oma.freeRaw(arena, @intFromPtr(freed));
    live[3] = null;

    const reused: *LargeSlot = @ptrFromInt(try t.expectNotNull(arena.alloc(oma.obj_size, oma.arena_capacity)));
    try t.expectEqual(@intFromPtr(freed), @intFromPtr(reused));
    live[3] = reused;
    try validateState(&oma);

    for (&live) |*slot| {
        if (slot.*) |obj| {
            oma.free(obj);
            slot.* = null;
        }
    }

    try t.expect(oma.arenas.first.load(.acquire) == null);
    try t.expectEqual(before, vm.PageAllocator.getAllocatedPages());
}

pub fn @"freeing tail entry rewinds arena next pointer"() !void {
    var oma = vm.ObjectAllocator.initCapacity(@sizeOf(TestObj), 8);
    defer oma.deinit();

    const first = try t.expectNotNull(oma.alloc(TestObj));
    const second = try t.expectNotNull(oma.alloc(TestObj));
    const arena = try t.expectNotNull(oma.contains(@intFromPtr(second)));

    const before = arena.next_ptr.load(.acquire);
    oma.free(second);
    const after = arena.next_ptr.load(.acquire);

    try t.expectEqual(before - oma.obj_size, after);

    oma.free(first);
    try t.expect(oma.arenas.first.load(.acquire) == null);
}

pub fn @"allocator grows by adding another arena when full"() !void {
    const before = vm.PageAllocator.getAllocatedPages();
    {
        var oma = vm.ObjectAllocator.initCapacity(@sizeOf(LargeSlot), 8);
        defer oma.deinit();

        for (0..oma.arena_capacity) |_| {
            _ = try t.expectNotNull(oma.alloc(LargeSlot));
        }

        _ = try t.expectNotNull(oma.alloc(LargeSlot));
        try t.expectEqual(@as(usize, 2), countArenas(&oma));
        try validateState(&oma);
    }

    try t.expectEqual(before, vm.PageAllocator.getAllocatedPages());
}

pub fn @"fuzz alloc and free preserves arena invariants"() !void {
    var oma = vm.ObjectAllocator.initCapacity(@sizeOf(TestObj), 32);
    defer oma.deinit();

    var rng = t.Fuzzer.init(0x0b1ec7a110c);
    var live: [128]?*TestObj = .{null} ** 128;

    for (0..256) |i| {
        const should_free = countLivePtrs(&live) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLivePtrIndex(&live, &rng).?;
            oma.free(live[idx].?);
            live[idx] = null;
        } else if (oma.alloc(TestObj)) |obj| {
            if (firstEmptyPtrIndex(&live)) |idx| {
                obj.* = .{ .a = i, .b = ~i };
                live[idx] = obj;
            } else {
                oma.free(obj);
            }
        }

        if ((i & 0xf) == 0) try validateState(&oma);
    }

    for (&live) |*slot| {
        if (slot.*) |obj| {
            oma.free(obj);
            slot.* = null;
        }
    }

    try t.expect(oma.arenas.first.load(.acquire) == null);
}

pub fn @"large arena requests become unavailable under pressure and recover"() !void {
    const before = vm.PageAllocator.getAllocatedPages();
    {
        const pages = try t.expectNotNull(findAvailableLargeArenaPages());
        var oma = vm.ObjectAllocator.initSized(@sizeOf(LargeSlot), pages);
        defer oma.deinit();

        var arenas: usize = 0;
        while (oma.newArena() != null) {
            arenas += 1;
        }

        try t.expect(arenas > 0);
        try t.expect(oma.newArena() == null);
    }

    try t.expectEqual(before, vm.PageAllocator.getAllocatedPages());
}

pub fn @"concurrent alloc free preserves arena invariants"() !void {
    var ctx = RaceContext.init(t.defaultWorkerCount());
    defer ctx.allocator.deinit();

    try t.runRace(RaceContext, "tests-oma-race", ctx.barrier.worker_count, max_wait_yields, &ctx, &raceWorker);
}

fn validateState(oma: *vm.ObjectAllocator) !void {
    const arena_size: usize = vm.ObjectAllocator.@"test".getArenaSize(oma);

    var node = oma.arenas.first.load(.acquire);
    while (node) |curr| : (node = curr.next) {
        const arena = vm.ObjectAllocator.Arena.fromNode(curr);
        const base = arena.getBase();
        const next = arena.next_ptr.load(.acquire);
        const alloc_num = arena.alloc_num.load(.acquire);

        try t.expect(base <= next and next <= base + arena_size);
        try t.expect(((next - base) % oma.obj_size) == 0);
        try t.expect(alloc_num > 0 and alloc_num <= oma.arena_capacity);

        var free_count: u16 = 0;
        var free_node = arena.free_list.first.load(.acquire);
        while (free_node) |free_curr| : (free_node = free_curr.next) {
            const addr = @intFromPtr(free_curr);
            try t.expect(arena.contains(addr, arena_size));
            try t.expect(((addr - base) % oma.obj_size) == 0);
            free_count += 1;
        }

        const used_slots: u16 = @intCast((next - base) / oma.obj_size);
        try t.expectEqual(used_slots, alloc_num + free_count);
    }
}

fn initRawAllocator(obj_size: u16, pages: u16) !vm.ObjectAllocator {
    const rank = vm.pagesToRankExact(pages);
    const phys = try t.expectNotNull(vm.PageAllocator.alloc(rank));
    errdefer vm.PageAllocator.free(phys, rank);
    return try vm.ObjectAllocator.initRaw(obj_size, phys, pages);
}

fn findAvailableLargeArenaPages() ?u16 {
    var rank: u8 = vm.PageAllocator.max_rank - 1;
    while (rank > 7) : (rank -= 1) {
        if (vm.PageAllocator.alloc(rank)) |phys| {
            vm.PageAllocator.free(phys, rank);
            return @intCast(vm.rankToPages(rank));
        }
    }

    return null;
}

fn countArenas(oma: *const vm.ObjectAllocator) usize {
    var count: usize = 0;
    var node = oma.arenas.first.load(.acquire);
    while (node) |curr| : (node = curr.next) {
        count += 1;
    }

    return count;
}

fn countLivePtrs(slots: []const ?*TestObj) usize {
    var live: usize = 0;
    for (slots) |slot| {
        if (slot != null) live += 1;
    }
    return live;
}

fn firstEmptyPtrIndex(slots: []const ?*TestObj) ?usize {
    for (slots, 0..) |slot, idx| {
        if (slot == null) return idx;
    }

    return null;
}

fn pickLivePtrIndex(slots: []const ?*TestObj, rng: *t.Fuzzer) ?usize {
    const live = countLivePtrs(slots);
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

    var rng = t.Fuzzer.init(@as(u64, smp.getIdx()) + 0x0b1ec7aa);
    var live: [48]?*[2]usize = .{null} ** 48;

    for (0..128) |_| {
        const should_free = countLiveWorkerPtrs(&live) > 0 and rng.coin();
        if (should_free) {
            const idx = pickLiveWorkerPtrIndex(&live, &rng).?;
            ctx.allocator.free(live[idx].?);
            live[idx] = null;
        } else if (ctx.allocator.alloc([2]usize)) |obj| {
            if (firstEmptyWorkerPtrIndex(&live)) |idx| {
                obj.* = .{ smp.getIdx(), rng.int(usize) };
                live[idx] = obj;
            } else {
                ctx.allocator.free(obj);
            }
        }
    }

    for (&live) |*slot| {
        if (slot.*) |obj| {
            ctx.allocator.free(obj);
            slot.* = null;
        }
    }

    ctx.barrier.workerDone();
    sched.terminate();
}

fn countLiveWorkerPtrs(slots: []const ?*[2]usize) usize {
    var live: usize = 0;
    for (slots) |slot| {
        if (slot != null) live += 1;
    }
    return live;
}

fn firstEmptyWorkerPtrIndex(slots: []const ?*[2]usize) ?usize {
    for (slots, 0..) |slot, idx| {
        if (slot == null) return idx;
    }

    return null;
}

fn pickLiveWorkerPtrIndex(slots: []const ?*[2]usize, rng: *t.Fuzzer) ?usize {
    const live = countLiveWorkerPtrs(slots);
    if (live == 0) return null;

    var nth = rng.range(live);
    for (slots, 0..) |slot, idx| {
        if (slot == null) continue;
        if (nth == 0) return idx;
        nth -= 1;
    }

    return null;
}
