//! # Logger
//! 
//! Provides implementation for `defaultLog(...)` used within `std.log`.
//! Manages thread-safe text output with color formatting.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const arch = lib.arch;
const dev = @import("dev.zig");
const lib = @import("lib.zig");
const serial = @import("dev/drivers/uart/8250.zig");
const sched = @import("sched.zig");
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const terminal = video.terminal;
const video = @import("video.zig");
const vm = @import("vm.zig");

pub const new_line = "\r\n";

const Message = struct {
    const Status = enum(u8) { free = 0, processing = 1, commited = 2 };
    const Level = enum(u8) {
        debug = 0,
        info = 1,
        warn = 2,
        err = 3,

        fn fromStd(level: std.log.Level) Level {
            return switch (level) {
                .debug => .debug,
                .info => .info,
                .warn => .warn,
                .err => .err,
            };
        }

        fn toColor(self: Level) std.Io.tty.Color {
            return switch (self) {
                .debug => .bright_black,
                .info => .reset,
                .warn => .bright_yellow,
                .err => .bright_red,
            };
        }
    };

    const Meta = packed struct(u64) {
        idx: u32 = 0,
        len: u16 = 0,
        level: Level = .debug,
        status: Status = .free,
    };

    meta: std.atomic.Value(Meta) = .init(.{}),
    time_ns: u64 = 0,
    text: [*]const u8,
    scope: [*:0]const u8,
};

const RingBuffer = struct {
    const Self = @This();

    const Cursor = packed struct(u64) {
        head: u32 = 0,
        tail: u32 = 0,

        inline fn capacity(self: Cursor, len: u32) u32 {
            return (self.head -% self.tail) & (len -% 1);
        }

        inline fn avail(self: Cursor, len: u32) u32 {
            return (self.head -% self.tail) & (len -% 1);
        }

        inline fn next(self: Cursor, len: u32) u32 {
            return (self.head +% 1) & (len -% 1);
        }

        inline fn inRange(self: Cursor, idx: u32) bool {
            return if (self.head < self.tail)
                (idx <= self.head or idx >= self.tail)
            else
                (idx >= self.tail and idx <= self.head);
        }
    };

    items: [*]Message = undefined,
    len: u32 = 0,

    cursor: std.atomic.Value(Cursor) = .init(.{}),

    pub fn addOne(self: *Self) *Message {
        var curr = self.cursor.load(.acquire);
        while (true) {
            var new = curr;
            new.head = new.next(self.len);

            if (new.head == new.tail) new.tail = new.next(self.len);

            curr = self.cursor.cmpxchgStrong(
                curr,
                new,
                .release,
                .monotonic,
            ) orelse break;
        }

        return &self.items[curr.head];
    }
};

const Stage = enum {
    boot,
    early,
    normal,
};

const panic_scope = "panic";

const tty_config: std.io.tty.Config = .escape_codes;
const msg_max_size = 512;

var boot_text_buffer: [vm.page_size]u8 = undefined;
var boot_ring_buffer: [64]Message = .{ Message{.scope = undefined, .text = undefined} } ** 64;

var stage: Stage = .boot;
var msg_ring: RingBuffer = .{ .items = &boot_ring_buffer, .len = boot_ring_buffer.len };
var msg_idx: std.atomic.Value(u32) = .init(0);
var text_buffer: []u8 = &boot_text_buffer;
var text_idx: std.atomic.Value(u32) = .init(0);
var dropped: std.atomic.Value(u32) = .init(0);
var wait_queue: sched.WaitQueue = .{};
var wait_lock: lib.sync.Spinlock = .{};

pub fn init() !void {
    const mem_size = vm.PageAllocator.getTotalPages() * vm.page_size;
    const buf_size: u32 = if (mem_size < 128 * lib.mb_size) blk: {
        break :blk lib.mb_size / 2;
    } else if (mem_size < 512 * lib.mb_size) blk: {
        break :blk 1 * lib.mb_size;
    } else blk: {
        break :blk 2 * lib.mb_size;
    };

    const msg_len = buf_size / (msg_max_size / 2);
    const msg_rank = vm.bytesToRank(msg_len * @sizeOf(Message));

    const buf_phys = vm.PageAllocator.alloc(vm.bytesToRank(buf_size)) orelse return error.NoMemory;
    errdefer vm.PageAllocator.free(buf_phys, vm.bytesToRank(buf_size));
    const msg_phys = vm.PageAllocator.alloc(msg_rank) orelse return error.NoMemory;
    errdefer vm.PageAllocator.free(msg_phys, msg_rank);

    text_buffer.ptr = @ptrFromInt(vm.getVirtLma(buf_phys));
    text_buffer.len = buf_size;

    const cursor = msg_ring.cursor.load(.acquire);

    msg_ring = .{ .cursor = .init(cursor), .items = @ptrFromInt(vm.getVirtLma(msg_phys)), .len = msg_len };
    @memset(msg_ring.items[cursor.head..msg_len], .{ .scope = undefined, .text = undefined });

    for (cursor.tail..cursor.head) |i| msg_ring.items[i] = boot_ring_buffer[i];

    stage = .early;
}

pub fn initWorker() !void {
    const worker = try sched.Task.createWorker("logger", &flushWorker, .{});
    sched.enqueue(worker);

    stage = .normal;
}

pub fn waitMessage() void {
    wait_lock.lock();
    sched.waitUnlock(&wait_queue, &wait_lock);
}

pub fn defaultLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype
) void {
    var buffer: [msg_max_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    writer.print(format, args) catch return;

    putLog(level, @tagName(scope), writer.buffered());
    notifyWaiters() catch {};
}

pub fn panicLog(msg: []const u8) void {
    const time_ns = sys.time.getUpTime().toNs();
    const log = blk: {
        for (0..10) |_| break :blk newLog() catch continue;

        flushBuffer("panic: log allocation failed\n");
        flushBuffer(msg);

        return;
    };

    log.scope = panic_scope;
    log.text = if (stage == .normal) blk: {
        const buffer = allocBuffer(@truncate(msg.len)) orelse break :blk msg.ptr;
        @memcpy(buffer, msg);

        break :blk buffer.ptr;
    } else msg.ptr;
    log.time_ns = time_ns;

    var meta = log.meta.raw;
    meta = .{
        .idx = meta.idx,
        .level = .err,
        .len = @truncate(msg.len),
        .status = .commited,
    };

    log.meta.store(meta, .release);

    switch (stage) {
        .boot,
        .early => flushBuffer(msg),
        .normal => notifyWaiters() catch {
            flushBuffer("panic: lock is dead?\n");
            flushBuffer(msg);
        },
    }
}

pub fn flushBuffer(str: []const u8) void {
    serial.write(str);

    if (!dev.VirtualTerminal.isEnabled() and
        video.terminal.isInitialized()
    ) video.terminal.write(str);
}

fn newLog() error{Drop}!*Message {
    const idx = msg_idx.fetchAdd(1, .release);
    const msg = msg_ring.addOne();

    const meta = msg.meta.load(.acquire);
    if (meta.status == .processing) return error.Drop;

    var new = meta;
    new = .{ .status = .processing, .idx = idx, .level = .debug, .len = 0 };

    if (msg.meta.cmpxchgStrong(
        meta, new, .release, .monotonic
    ) != null) return error.Drop;

    return msg;
}

fn putLog(level: std.log.Level, scope: [*:0]const u8, text: []const u8) void {
    const msg = newLog() catch return drop();
    var meta = msg.meta.raw;

    if (allocBuffer(@truncate(text.len))) |buffer| {
        msg.time_ns = sys.time.getUpTime().toNs();
        msg.scope = scope;
        msg.text = buffer.ptr;

        @memcpy(buffer, text);
        meta.level = .fromStd(level);
        meta.len = @truncate(text.len);
        meta.status = .commited;
    } else {
        meta.status = .free;
    }

    msg.meta.store(meta, .release);
}

fn allocBuffer(len: u32) ?[]u8 {
    var idx = text_idx.load(.acquire);
    while (true) {
        // FIXME: Implement tail check!
        const msg_tail = msg_ring.items[msg_ring.cursor.load(.acquire).tail];
        const tail = @intFromPtr(msg_tail.text) -| @intFromPtr(text_buffer.ptr);

        const avail = if (tail != idx) (tail -% idx) & (text_buffer.len -% 1) else text_buffer.len;
        if (avail < len) return null;

        var curr = idx;
        var next = idx + len;
        if (next >= text_buffer.len) {
            curr = 0;
            next = len;
        }

        idx = text_idx.cmpxchgStrong(
            idx, next, .release, .monotonic
        ) orelse return text_buffer[curr..next];
    }
}

fn notifyWaiters() error{Timeout}!void {
    if (stage != .normal or
        smp.getLocalData().isInInterrupt() or
        dev.intr.isEnabledForCpu() == false
    ) return;

    try wait_lock.lockTimeout(std.time.us_per_s / 2);
    defer wait_lock.unlock();

    sched.awakeAll(&wait_queue);
}

fn flushWorker(_: usize) noreturn {
    var buffer: [vm.page_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var i: u32 = 0;
    var idx: u32 = 0;
    while (true)  {
        var cursor = msg_ring.cursor.load(.acquire);
        if (!cursor.inRange(i)) i = cursor.head;

        while (cursor.inRange(i)) : ({
            i = (i +% 1) & (msg_ring.len -% 1);
            cursor = msg_ring.cursor.load(.acquire);
        }) {
            const msg = &msg_ring.items[i];
            const meta = msg.meta.load(.acquire);
            if (meta.status != .commited) break;
            if (meta.idx <= idx) continue;

            idx = meta.idx;
            defer writer.end = 0;

            tty_config.setColor(&writer, meta.level.toColor()) catch continue;
            defer tty_config.setColor(&writer, .reset) catch {};

            const time: sys.time.Time = .fromNs(msg.time_ns);
            if (msg.scope == panic_scope) {
                @branchHint(.cold);
                writer.print("{f} ", .{std.fmt.alt(time, .formatUs)}) catch {};

                flushBuffer(writer.buffered());
                flushBuffer(msg.text[0..meta.len]);

                continue;
            }

            writer.print("{f} [{t}] ", .{std.fmt.alt(time, .formatUs), meta.level}) catch {};
            if (msg.scope != @tagName(.default)) writer.print("{s}: ", .{msg.scope}) catch {};

            writer.writeAll(msg.text[0..meta.len]) catch {};
            writer.writeAll(new_line) catch {};

            const new_meta = msg.meta.load(.acquire);
            if (meta.idx != new_meta.idx) { @branchHint(.cold); continue; }

            flushBuffer(writer.buffered());
        }

        waitMessage();
    }
}

inline fn drop() void {
    _ = dropped.fetchAdd(1, .release);
}
