const std = @import("std");

const t = @import("../framework.zig");
const h = @import("../vfs_harness.zig");
const vfs = @import("../../src/kernel/vfs.zig");

pub fn @"configured backend mounts as isolated virtual root"() !void {
    const harness = try h.Harness.init(.{ .backend = "tmpfs" });

    try t.expectEqual(vfs.Inode.Type.directory, harness.root.inode.type);
    try t.expect(vfs.isFsRoot(harness.root));
    try t.expect(std.mem.eql(u8, "tmpfs", harness.fs.name));
}

pub fn @"lookup resolves absolute relative dot and dotdot paths"() !void {
    var harness = try h.Harness.init(.{});
    const etc = try harness.root.makeDirectory("etc", .{});
    const config = try etc.createFile("config", .{});
    const nested = try etc.makeDirectory("nested", .{});
    const leaf = try nested.createFile("leaf", .{});

    try t.expectEqual(config, try vfs.lookup(harness.root, harness.root, "/etc/config"));
    try t.expectEqual(config, try vfs.lookup(harness.root, etc, "./config"));
    try t.expectEqual(etc, try vfs.lookup(harness.root, nested, ".."));
    try t.expectEqual(leaf, try vfs.lookup(harness.root, nested, "../nested/leaf"));
}

pub fn @"lookup rejects empty path and reports missing components"() !void {
    const harness = try h.Harness.init(.{});

    try t.expectError(error.InvalidArgs, vfs.lookup(harness.root, harness.root, ""));
    try t.expectError(error.NoEnt, vfs.lookup(harness.root, harness.root, "/missing"));
}

pub fn @"lookup stops at regular file when path expects directory"() !void {
    var harness = try h.Harness.init(.{});
    const file = try harness.root.createFile("plain", .{});

    try t.expectEqual(file, try vfs.lookup(harness.root, harness.root, "/plain"));
    try t.expectError(error.NotDirectory, vfs.lookup(harness.root, harness.root, "/plain/child"));
}
