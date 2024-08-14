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
            else if (std.mem.eql(u8, arg, "-src")) {
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
            CfgInitError.unknownArg => std.log.err("Unknown input argument found", .{}),
            CfgInitError.expectedArg => std.log.err("Expected file/directory path or name after '-o'/'-src'/'-n", .{})
        }
        return;
    };

    if (config.output == null) {
        std.log.err("Output directory not specified, please specify path using '-o'", .{});
        return;
    }
    if (config.src_dir == null) {
        std.log.err("Source directory not specified, please specify path using '-src'", .{});
        return;
    }

    try makeSrcTar(config, allocator);
}

fn makeSrcTar(config: Config, allocator: std.mem.Allocator) !void {
    var src_dir = try std.fs.openDirAbsolute(config.src_dir.?, .{ .iterate = true }) ;
    defer src_dir.close();

    const tar_file = try std.fs.createFileAbsolute(config.output.?, .{});
    defer tar_file.close();

    try writeDir(src_dir, config.name orelse "", tar_file, allocator);
}

fn writeDir(src_dir: std.fs.Dir, name: []const u8, tar_file: std.fs.File, allocator: std.mem.Allocator) !void {
    var src_walker = try src_dir.walk(allocator);
    defer src_walker.deinit();

    const padding_buffer = [1]u8{0} ** 512;

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

        const stat = try file.stat();

        var file_header = std.tar.output.Header.init();
        file_header.typeflag = .regular;

        try file_header.setPath(name, entry.path);
        try file_header.setSize(stat.size);
        try file_header.updateChecksum();

        const header_bytes = std.mem.asBytes(&file_header);
        const padding = p: {
            const remainder: u16 = @intCast(stat.size % 512);
            const n = if (remainder > 0) 512 - remainder else 0;
            break :p padding_buffer[0..n];
        };

        var header_and_trailer: [2]std.posix.iovec_const = .{
            .{ .base = header_bytes.ptr, .len = header_bytes.len },
            .{ .base = padding.ptr, .len = padding.len },
        };

        try tar_file.writeFileAll(file, .{
            .in_len = stat.size,
            .headers_and_trailers = &header_and_trailer,
            .header_count = 1,
        });
    }
}