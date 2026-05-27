const t = @import("framework.zig");
const vfs = @import("../src/kernel/vfs.zig");

pub const Options = struct {
    backend: []const u8 = "tmpfs",
};

pub const Harness = struct {
    fs: *vfs.FileSystem,
    mount_point: *vfs.MountPoint,
    root: *vfs.Dentry,

    pub fn init(opts: Options) !Harness {
        const fs = vfs.getFs(opts.backend) orelse return error.NoFs;
        errdefer fs.deref();

        if (fs.kind() != .virtual) return error.InvalidArgs;

        const mount_point = vfs.MountPoint.new() orelse return error.NoMemory;
        const virt = try fs.mountVirtual();

        mount_point.* = .init(fs, virt.root, .{ .virt = virt });
        virt.root.ctx = .{ .virt = &mount_point.ctx.virt };
        virt.root.meta.fs = .virt;

        return .{
            .fs = fs,
            .mount_point = mount_point,
            .root = virt.root,
        };
    }

    pub fn lookup(self: *const Harness, path: []const u8) !*vfs.Dentry {
        return vfs.lookup(self.root, self.root, path);
    }

    pub fn requireDirectory(self: *const Harness, path: []const u8) !*vfs.Dentry {
        const dentry = try self.lookup(path);
        try t.expectEqual(vfs.Inode.Type.directory, dentry.inode.type);
        return dentry;
    }

    pub fn requireFile(self: *const Harness, path: []const u8) !*vfs.Dentry {
        const dentry = try self.lookup(path);
        try t.expectEqual(vfs.Inode.Type.regular_file, dentry.inode.type);
        return dentry;
    }
};

pub const IterEntry = struct {
    name: []const u8,
    inode: usize,
    @"type": vfs.Inode.Type,
};

pub fn collectEntries(dentry: *const vfs.Dentry, buffer: []IterEntry) ![]IterEntry {
    const State = struct {
        iter: vfs.Dentry.Iterator = .{ .callback = fill },
        entries: []IterEntry,
        used: usize = 0,

        fn fill(iter: *vfs.Dentry.Iterator, name: []const u8, inode: usize, @"type": vfs.Inode.Type) bool {
            const self: *@This() = @fieldParentPtr("iter", iter);
            if (self.used >= self.entries.len) return false;

            self.entries[self.used] = .{
                .name = name,
                .inode = inode,
                .@"type" = @"type",
            };
            self.used += 1;
            return true;
        }
    };

    var state = State{ .entries = buffer };
    try dentry.iterate(&state.iter);

    return state.entries[0..state.used];
}
