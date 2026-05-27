
pub const lib_sync = @import("lib_sync.zig");
pub const smp = @import("smp.zig");

pub const @"vm.PageAllocator" = @import("vm_page_allocator.zig");
pub const @"vm.ObjectAllocator" = @import("vm_object_allocator.zig");
pub const @"vm.gpa" = @import("vm_gpa.zig");

pub const vfs = @import("vfs.zig");
pub const @"vfs.Dentry" = @import("vfs_dentry.zig");
pub const @"vfs.Inode" = @import("vfs_inode.zig");
//pub const @"vfs.File" = @import("vfs_file.zig");
