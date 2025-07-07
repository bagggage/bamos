// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

//! # TAR Archive utilty
//! 
//! Used as part of the build chain to
//! create tar archives.
//!
//! Usage:
//! `tar -o <output dir> -s <source dir> [-n <path prefix>]`
//! 
//! Arguments:
//! - `-o <path>`   output archive name
//! - `-s <path>`   source directory
//! - `-n <name>`   optional archived files root path

const std = @import("std");

const Config = struct {
    output: ?[]const u8 = null,
    src_dir: ?[]const u8 = null,
    name: ?[]const u8 = null,

    pub fn init(args: *std.process.ArgIterator) CfgInitError!Config {
        var result = Config{};

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                result.output = args.next() orelse return CfgInitError.expectedArg;
            }
            else if (std.mem.eql(u8, arg, "-s")) {
                result.src_dir = args.next() orelse return CfgInitError.expectedArg;
            }
            else if (std.mem.eql(u8, arg, "-n")) {
                result.name = args.next() orelse return CfgInitError.expectedArg;
            }
            else {
                return CfgInitError.unknownArg;
            }
        }

        return result;
    }
};

const CfgInitError = error {
    expectedArg,
    unknownArg,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{.safety = true}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program file name
    _ = args.next() orelse unreachable;

    const config = Config.init(&args) catch |err| {
        switch (err) {
            CfgInitError.unknownArg => std.log.err("unknown input argument found", .{}),
            CfgInitError.expectedArg => std.log.err("expected file/directory path or name after '-o'/'-s'/'-n", .{})
        }
        return error.failed;
    };

    if (config.output == null) {
        std.log.err("output directory not specified, please specify path using '-o'", .{});
        return error.failed;
    }
    if (config.src_dir == null) {
        std.log.err("source directory not specified, please specify path using '-s'", .{});
        return error.failed;
    }

    try makeSrcTar(config, allocator);
}

fn makeSrcTar(config: Config, allocator: std.mem.Allocator) !void {
    var src_dir =
        if (config.src_dir.?[0] == '/')
            try std.fs.openDirAbsolute(config.src_dir.?, .{ .iterate = true })
        else 
            try std.fs.cwd().openDir(config.src_dir.?, .{ .iterate = true });
    defer src_dir.close();

    const tar_file = 
        if (config.output.?[0] == '/')
            try std.fs.createFileAbsolute(config.output.?, .{})
        else
            try std.fs.cwd().createFile(config.output.?, .{});
    defer tar_file.close();

    var file_writer = tar_file.writer();

    var tar_writer = std.tar.writer(file_writer.any());
    try writeDir(src_dir, config.name orelse "", &tar_writer, allocator);

    return tar_writer.finish();
}

fn writeDir(src_dir: std.fs.Dir, name: []const u8, tar_writer: anytype, allocator: std.mem.Allocator) !void {
    var src_walker = try src_dir.walk(allocator);
    defer src_walker.deinit();

    var buffer: [512]u8 = undefined;

    while (try src_walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                if (std.mem.eql(u8, entry.basename, "test.zig")) continue;
                if (std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
            },
            else => continue
        }

        const file = try src_dir.openFile(entry.path, .{});
        defer file.close();

        const sub_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{name, entry.path});
        try tar_writer.writeFile(sub_path, file);
    }
}