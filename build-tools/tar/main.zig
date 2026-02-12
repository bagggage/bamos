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

const FileReader = struct {
    file: std.fs.File,
    pos: u64 = 0,
    size: u64,
    need_new_line: bool,

    pub const Error = std.fs.File.ReadError;

    pub inline fn init(file: std.fs.File) !FileReader {
        const size = try file.getEndPos();
        var buf: [1]u8 = undefined;

        try file.seekTo(size - 1);

        _ = try file.read(&buf);
        try file.seekTo(0);

        std.log.err("file end: {any}", .{buf[0]});

        return .{
            .file = file,
            .size = size,
            .need_new_line = (buf[0] != '\n')
        };
    }

    pub fn read(self: *FileReader, buf: []u8) Error!usize {
        const readed = try self.file.read(buf);
        self.pos += readed;

        if (buf.len > readed) std.log.err("some strage: {}/{} - {}=>{}", .{buf.len,readed,self.pos,self.size});

        if (self.pos == self.size and self.need_new_line) {
            std.log.err("insert '\\n'", .{});
            buf[readed] = '\n';
            self.pos += 1;

            return readed + 1;
        }

        return readed;
    }

    pub fn getSize(self: *const FileReader) usize {
        return if (self.need_new_line) self.size + 1 else self.size;
    }
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

    const buffer = try allocator.alloc(u8, std.heap.pageSize());
    defer allocator.free(buffer);

    var file_writer = tar_file.writer(buffer);
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &file_writer.interface };
    try writeDir(src_dir, config.name orelse "", &tar_writer, allocator);

    return try file_writer.interface.flush();
}

fn writeDir(src_dir: std.fs.Dir, name: []const u8, tar_writer: *std.tar.Writer, allocator: std.mem.Allocator) !void {
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

        var file_reader = file.reader(&.{});
        const sub_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{name, entry.path});

        try tar_writer.writeFileStream(
            sub_path,
            try file_reader.getSize(),
            &file_reader.interface,
            .{ .mode = 0o0644, }
        );
    }
}