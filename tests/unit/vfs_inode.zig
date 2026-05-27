const t = @import("../framework.zig");
const vfs = @import("../../src/kernel/vfs.zig");

pub fn @"getRole prefers root owner group and others in order"() !void {
    const inode = vfs.Inode{
        .index = 1,
        .type = .regular_file,
        .uid = 1000,
        .gid = 2000,
        .cache_ctrl = .{ .write_back = null },
    };

    try t.expectEqual(vfs.Role.user, inode.getRole(0, 123));
    try t.expectEqual(vfs.Role.user, inode.getRole(1000, 123));
    try t.expectEqual(vfs.Role.group, inode.getRole(123, 2000));
    try t.expectEqual(vfs.Role.others, inode.getRole(123, 456));
}

pub fn @"checkAccess and anyAccess respect permission masks"() !void {
    const inode = vfs.Inode{
        .index = 2,
        .type = .regular_file,
        .perm = vfs.Permissions.makeInt(.rw, .r, .none),
        .cache_ctrl = .{ .write_back = null },
    };

    try t.expect(inode.checkAccess(.r, .user));
    try t.expect(inode.checkAccess(.w, .user));
    try t.expect(!inode.checkAccess(.x, .user));

    try t.expect(inode.checkAccess(.r, .group));
    try t.expect(!inode.checkAccess(.w, .group));

    try t.expect(!inode.anyAccess(.rw, .others));
    try t.expect(inode.anyAccess(.r, .group));
}
