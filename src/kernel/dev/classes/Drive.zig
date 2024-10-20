//! # Block device high-level interface

const Self = @This();

pub const VTable = struct {
    pub const ReadFn = *const fn(obj: *Self, lba_offset: usize, buffer: []u8) bool;
    pub const WriteFn = *const fn(obj: *Self, lba_offset: usize, buffer: []const u8) bool;

    read: ReadFn,
    write: WriteFn,
};

lba_size: u16,
capacity: usize,
vtable: *VTable,

pub inline fn read(self: *Self, lba_offset: usize, buffer: []u8) bool {
    if ((lba_offset * self.lba_size) + buffer.len > self.capacity) return false;

    return self.vtable.read(self, lba_offset, buffer);
}

//pub inline fn write(self: *Self, offset: usize, buffer: []const u8) bool {
//    
//}