/// Simple program for generating kernel debug information.

const std = @import("std");
const maker = @import("maker.zig");

const Allocator = std.heap.GeneralPurposeAllocator(.{});
const Buffer_t = [std.fs.max_path_bytes]u8;

var output_buffer: Buffer_t = undefined;
var input_buffer: Buffer_t = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{.safety = true}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program file name
    _ = args.next();

    var config: maker.Config = undefined;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            config.output = args.next() orelse return error.ExpectedOutputFilePath;
        }
        else {
            config.input = arg;
        }
    }

    try maker.makeDebugInfo(&config, allocator);
}