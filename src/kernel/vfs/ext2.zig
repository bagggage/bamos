const vfs = @import("../vfs.zig");

var fs = vfs.FileSystem.init(
    "ext2",
    undefined,
    undefined
);

pub fn init() !void {
    try vfs.registerFs(&fs);
}

pub fn deinit() void {
    vfs.unregisterFs(&fs);
}

//fn mount()