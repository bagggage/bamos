//! # Atomic Reference Counter

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

pub fn RefCount(comptime UintType: type) type {
    comptime {
        const uint_type = @typeInfo(UintType);
        if (uint_type != .Int or uint_type.Int.signedness != .unsigned) {
            @compileError("`UintType` must be unsigned integer, e.g. `u8`,`u16`,`u32` etc.");
        }
    }

    return struct {
        const Self = @This();

        count: std.atomic.Value(UintType) = .{ .raw = 0 },

        pub inline fn get(self: *Self) void {
            // no synchronization necessary; just updating a counter.
            _ = self.count.fetchAdd(1, .monotonic);
        }

        pub inline fn put(self: *Self) void {
            // release ensures code before put() happens-before the
            // count is decremented as dropFn could be called by then.
            if (self.count.fetchSub(1, .release) == 1) {
                // seeing 1 in the counter means that other put()s have happened,
                // but it doesn't mean that uses before each put() are visible.
                // The load acquires the release-sequence created by previous unref()s
                // in order to ensure visibility of uses before dropping.
                _ = self.count.load(.acquire);
            }
        }

        pub inline fn count(self: *const Self) UintType {
            return self.count.load(.acquire);
        }
    };
}