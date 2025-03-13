//! # Atomic Reference Counter

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

pub fn RefCount(comptime UintType: type) type {
    comptime {
        const uint_type = @typeInfo(UintType);
        if (uint_type != .int or uint_type.int.signedness != .unsigned) {
            @compileError("`UintType` must be unsigned integer, e.g. `u8`,`u16`,`u32` etc.");
        }
    }

    return struct {
        const Self = @This();

        value: std.atomic.Value(UintType) = .{ .raw = 1 },

        pub inline fn set(self: *Self, value: UintType) void {
            self.value.store(value, .acquire);
        }

        pub inline fn get(self: *Self) bool {
            var old = self.count();

            while (true) {
                if (old == 0) return false;

                if (self.value.cmpxchgWeak(
                    old, old + 1,
                    .acquire, .monotonic)
                ) |new_old| {
                    old = new_old; continue;
                }

                return true;
            }

            unreachable;
        }

        pub inline fn put(self: *Self) bool {
            // release ensures code before put() happens-before the
            // count is decremented as dropFn could be called by then.
            if (self.value.fetchSub(1, .release) == 1) {
                // seeing 1 in the counter means that other put()s have happened,
                // but it doesn't mean that uses before each put() are visible.
                // The load acquires the release-sequence created by previous put()s
                // in order to ensure visibility of uses before dropping.
                _ = self.value.load(.acquire);
                return true;
            }

            return false;
        }

        pub inline fn count(self: *const Self) UintType {
            return self.value.load(.acquire);
        }

        pub inline fn inc(self: *Self) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub inline fn dec(self: *Self) void {
            _ = self.value.fetchSub(1, .release);
        }
    };
}