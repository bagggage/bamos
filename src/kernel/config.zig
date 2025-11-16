//! # Kernel configuration utility

const std = @import("std");

const boot = @import("boot.zig");
const lib = @import("lib.zig");
const log = std.log.scoped(.config);
const vm = @import("vm.zig");

const EnumParseResult = extern struct {
    value: usize = undefined,
    valid: bool = false
};

fn EnumParser(comptime T: type) type {
    return opaque {
        pub fn parse(tag_name: [*]const u8, len: usize) callconv(.c) EnumParseResult {
            const tag = std.meta.stringToEnum(T, tag_name[0..len]) orelse {
                return .{};
            };
            return .{
                .value = @intFromEnum(tag),
                .valid = true
            };
        }
    };
}

const Map = lib.AutoHashTable([]const u8);
const Value = struct {
    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma
    };

    string: []const u8 = &.{},
    map_ent: Map.Entry = .{},

    inline fn fromEntry(entry: *Map.Entry) *Value {
        return @fieldParentPtr("map_ent", entry);
    }
};

var map: Map = undefined;
var env: []const u8 = undefined;

pub fn init() !void {
    const raw_env = boot.getEnvironment();
    env = raw_env[0..std.mem.len(raw_env)];

    map = try .init(vm.page_size * 2);
    try parseConfig();
}

pub inline fn get(key: []const u8) ?[]const u8 {
    return Value.fromEntry(map.get(key) orelse return null).string;
}

pub fn getAs(comptime T: type, key: []const u8) ?T {
    checkType(T);
    const value = get(key) orelse return null;
    return parseValue(T, value) catch |err| {
        log.warn("\"{s}\" has invalid value: \"{s}\" ({s}), expected format: {s}", .{
            key, value, @errorName(err), @typeName(T)
        });
    };
}

/// Comptime utility for marking a specific
/// variable for configuration at boot.
fn autoInit(comptime T: type, comptime ptr: *T, comptime name: []const u8) void {
    const export_name = name++typeSign(T);
    @export(ptr, .{ .name = export_name, .section = "config" });

    const info = @typeInfo(T);
    if (info == .@"enum") {
        @export(&EnumParser(T).parse, .{ .name = "EP_"++@typeName(T) });
    }
}

/// Returns specific sign to dynamicly identify variable type.
/// 
/// Sign specification:
/// - `b`: boolean;
/// - `i`: signed integer;
/// - `u`: unsigned integer;
/// - `f`: float;
/// - `o`: optional*;
/// - `s`: string**;
/// - `e`: enum***.
/// 
/// \* - Optional used as prefix for other sign,
/// this is means that if there are no definition in config,
/// or value has incorrect format, variable would be setted to `null`.
/// 
/// \** - String is a pointer to `const` array of bytes(`u8`) or
/// slice. If variable is a slice, the sign would also have postfix `s`.
/// Examples: `s` - string pointer, `ss` - string slice,
/// `oss` - nullable string slice (`?[]const u8`).
/// 
/// \*** - To parse enum kernel has to know exect type name to find
/// specific parse function, so sign also contains postfix with enum type name
/// (like: `eMyEnum`).
/// 
/// The size of variable is determined from kernel ELF file symtable,
/// so no reason to include size information into a sign. 
fn typeSign(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    return switch (comptime info) {
        .bool => "b",
        .int => |int| if (int.signedness == .signed) "i" else "u",
        .float => "f",
        .@"enum" => "e"++@typeName(T),
        .pointer => |ptr| blk: {
            if (
                ptr.is_const == false or
                ptr.child != u8 or
                ptr.size == .one
            ) unsupportedType(T);

            comptime var sign: []const u8 = "";

            if (ptr.is_allowzero) sign = "o";
            sign = sign++"s";

            if (ptr.size == .slice) sign = sign++"s";

            break :blk sign;
        },
        .optional => |op| "o"++typeSign(op.child),
        else => unsupportedType(T)
    };
}

inline fn unsupportedType(comptime T: type) noreturn {
    @compileError("Unsupported configuration variable type: \""++@typeName(T)++"\"");
}

fn checkType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool,
        .int,
        .float,
        .@"enum" => {},
        .pointer => |ptr| {
            if (
                ptr.is_const == false or
                ptr.child != u8 or
                ptr.size == .one
            ) unsupportedType(T);
        },
        .optional => |op| checkType(op.child),
        else => unsupportedType(T)
    }
}

fn parseConfig() !void {
    var line_iter = std.mem.splitScalar(u8, env, '\n');
    var i: u32 = 1;

    while (line_iter.next()) |line| : (i += 1) {
        const trim = std.mem.trim(u8, line, " \t");
        if (trim.len == 0) continue;

        // Fast check on comment.
        switch (trim.ptr[0]) {
            '#' => continue,
            '/' => if (trim.ptr[1] == '/') continue,
            else => {}
        }

        var pair_iter = std.mem.splitScalar(u8, trim, '=');
        const key = pair_iter.first();
        const value = readValue(pair_iter.rest());

        if (!validateKey(key) or value == null) {
            log.warn("invalid key-value pair at line:{}", .{i});
            continue;
        }

        try put(key, value.?);
    }
}

fn validateKey(key: []const u8) bool {
    for (key) |c| {
        if (
            std.ascii.isAlphanumeric(c) or
            c == '_' or c == '.'
        ) continue;
        return false;
    }

    return true;
}

fn readValue(buf: []const u8) ?[]const u8 {
    if (buf.len == 0 or std.ascii.isWhitespace(buf[0])) return null;

    const c = buf[0];
    if (c == '\"' or c == '\'') {
        const i = (std.mem.indexOfScalar(u8, buf[1..], c) orelse return null) + 1;
        if (i != buf.len - 1) return null;
    }

    return buf;
}

fn parseValue(comptime T: type, value: []const u8) !T {
    const info = @typeInfo(T);
    switch (comptime info) {
        .bool => return parseBool(value),
        .int => return std.fmt.parseInt(T, value, 0),
        .float => return std.fmt.parseFloat(T, value),
        .@"enum" => return std.meta.stringToEnum(T, value) orelse error.InvalidValue,
        .pointer => |ptr| {
            if (comptime ptr.size == .slice) return value;
            if (comptime ptr.size == .many) return value.ptr;
            return @ptrCast(value.ptr);
        },
        .optional => |op| {
            if (
                std.mem.eql(u8, value, "none") or
                std.mem.eql(u8, value, "null")
            ) return null;

            return try parseValue(op.child, value);
        },
        else => unsupportedType(T)
    }
}

fn parseBool(value: []const u8) !bool {
    if (value.len == 1) {
        const c = value[0];

        return switch (c) {
            '1',
            'y' => true,
            '0',
            'n' => false,
            else => error.InvalidValue
        };
    }

    if (
        std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "true")
    ) return true;
    if (
        std.mem.eql(u8, value, "no") or
        std.mem.eql(u8, value, "false")
    ) return false;

    return error.InvalidValue;
}

fn put(key: []const u8, value: []const u8) !void {
    const val = vm.auto.alloc(Value) orelse return error.NoMemory;
    val.* = .{ .string = value };

    map.insert(key, &val.map_ent);
}