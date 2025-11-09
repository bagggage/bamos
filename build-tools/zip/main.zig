// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

//! # ZIP Archive utility
//!
//! Used as part of the build chain to decompress
//! archived `.zip` binary files.
//!
//! Usage:
//! `zip <archive> -o <output dir>`
//!
//! Arguments:
//! - `<archive>`   .zip archive file name
//! - `-o <path>`   output directory

const std = @import("std");
const builtin = @import("builtin");
const zip = std.zip;

const Config = struct {
    output: ?[]const u8 = null,
    input: ?[]const u8 = null,

    pub fn init(args: *std.process.ArgIterator) CfgInitError!Config {
        var result = Config{};

        result.input = args.next() orelse return CfgInitError.expectedArg;
        if (result.input.?[0] == '-') return CfgInitError.expectedArg;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                result.output = args.next() orelse return CfgInitError.expectedArg;
            } else {
                return CfgInitError.unknownArg;
            }
        }

        return result;
    }
};

const CfgInitError = error{
    expectedArg,
    unknownArg,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program file name
    _ = args.next() orelse unreachable;

    const config = Config.init(&args) catch |err| {
        switch (err) {
            CfgInitError.unknownArg => std.log.err("unknown input argument found", .{}),
            CfgInitError.expectedArg => std.log.err("expected file/directory path '<archive>'/'-o <file name>'", .{}),
        }
        return error.failed;
    };

    if (config.output == null) {
        std.log.err("output directory not specified, please specify path using '-o'", .{});
        return error.failed;
    }
    if (config.input == null) {
        std.log.err("input archive not specified", .{});
        return error.failed;
    }

    try unzip(config);
}

fn unzip(config: Config) !void {
    var out_dir =
        if (config.output.?[0] == '/')
            std.fs.openDirAbsolute(config.output.?, .{}) catch |err| blk: {
                if (err != std.fs.File.OpenError.FileNotFound) return err;
                try std.fs.makeDirAbsolute(config.output.?);
                break :blk try std.fs.openDirAbsolute(config.output.?, .{});
            }
        else
            try std.fs.cwd().makeOpenPath(config.output.?, .{});
    defer out_dir.close();

    const zip_file =
        if (config.input.?[0] == '/')
            try std.fs.openFileAbsolute(config.input.?, .{})
        else
            try std.fs.cwd().openFile(config.input.?, .{});
    defer zip_file.close();

    var buffer: [512]u8 = undefined;
    var reader = zip_file.reader(&buffer);
    var iter = try zip.Iterator.init(&reader);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        try entry.extract(&reader, .{}, &filename_buf, out_dir);

        const file = try out_dir.openFile(filename_buf[0..entry.filename_len], .{});
        defer file.close();

        // Add execute permissions.
        if (comptime builtin.os.tag != .windows) try file.chmod(0o755);
    }
}
