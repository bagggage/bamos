//! # Linear framebuffer device driver

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const boot = @import("../../../boot.zig");
const dev = @import("../../../dev.zig");
const Framebuffer = dev.classes.Framebuffer;
const IoCtl = Framebuffer.IoCtl;
const lib = @import("../../../lib.zig");
const log = std.log.scoped(.@"video.fb");
const sys = @import("../../../sys.zig");
const vfs = @import("../../../vfs.zig");
const video = @import("../../../video.zig");
const vm = @import("../../../vm.zig");

const ops: Framebuffer.Operations = .{
    .read = &fbRead,
    .write = &fbWrite,
    .fill_rect = &fbFillRect,
    .copy_area = &fbCopyArea,
    .image_blit = &fbImageBlit,
    .blank = &fbBlank,
    .mmap = &fbMmap,
    .get_capabilities = &fbGetCapabilities,
    .control = &fbControl,
};

const map_unit_ops: sys.AddressSpace.MapUnit.Operations = .{
    .pageFault = &mapUnitPageFault,
    .unmapPage = &mapUnitUnmapPage,
};

var fb_0: Framebuffer = undefined;

pub fn init() !void {
    var boot_fb: video.Framebuffer = undefined;
    boot.getFb(&boot_fb);

    const phys = vm.translateVirtToPhys(@intFromPtr(boot_fb.base)) orelse return error.Uninitialized;
    const size = boot_fb.scanline * boot_fb.height;

    try fb_0.setup(
        "linear-fb",
        &ops,
        @intCast(boot_fb.width),
        @intCast(boot_fb.height),
        boot_fb.scanline,
        boot_fb.format,
        @intFromPtr(boot_fb.base),
        phys,
        size,
    );
}

fn fbRead(self: *Framebuffer, offset: usize, buffer: []u8) usize {
    const mem = memoryRegion(self);
    if (offset >= mem.len) {
        @branchHint(.unlikely);
        return 0;
    }

    const end = @min(offset + buffer.len, mem.len);
    const len = end -% offset;

    @memcpy(buffer[0..len], mem[offset..end]);
    return len;
}

fn fbWrite(self: *Framebuffer, offset: usize, buffer: []const u8) usize {
    const mem = memoryRegion(self);
    if (offset >= mem.len) {
        @branchHint(.unlikely);
        return 0;
    }

    const end = @min(offset + buffer.len, mem.len);
    const len = end -% offset;

    @memcpy(mem[offset..end], buffer[0..len]);
    return len;
}

fn fbFillRect(self: *Framebuffer, fill: *const IoCtl.FillRect) void {
    if (fill.rect.dx >= self.width or fill.rect.dy >= self.height) return;

    const mem = memoryRegion(self);
    const pix: []u32 = @ptrCast(@alignCast(mem));

    const y_end = @min(self.height, fill.rect.dy +% fill.rect.height);
    const x_end = @min(self.width, fill.rect.dx +% fill.rect.width);
    const x_len = x_end -% fill.rect.dx;

    var offset = (self.scanline / @sizeOf(u32)) * fill.rect.dy;
    for (fill.rect.dy..y_end) |_| {
        const start_offset = offset +% fill.rect.dx; 
        const end_offset = start_offset +% x_len;

        @memset(pix[start_offset..end_offset], fill.color);
        offset += self.scanline / @sizeOf(u32);
    }
}

fn fbCopyArea(self: *Framebuffer, copy_area: *const IoCtl.CopyArea) void {
    _ = self; _ = copy_area;
    log.info("copy area", .{});
}

fn fbImageBlit(self: *Framebuffer, image: *const IoCtl.Image) void {
    if (image.rect.dx >= self.width or image.rect.dy >= self.height) return;

    const mem = memoryRegion(self);
    const pix: []u32 = @ptrCast(@alignCast(mem));
    const img: [*]const u32 = @ptrCast(@alignCast(image.data));

    const y_end = @min(self.height, image.rect.dy +% image.rect.height);
    const x_end = @min(self.width, image.rect.dx +% image.rect.width);
    const x_len = x_end -% image.rect.dx;

    var mem_offset = (self.scanline / @sizeOf(u32)) * image.rect.dy;
    var img_offset: u32 = 0;

    for (image.rect.dy..y_end) |_| {
        const start_offset = mem_offset +% image.rect.dx; 
        const end_offset = start_offset +% x_len;

        @memcpy(pix[start_offset..end_offset], img[img_offset..img_offset + x_len]);

        mem_offset += self.scanline / @sizeOf(u32);
        img_offset += image.rect.width;
    }
}

fn fbBlank(self: *Framebuffer) void {
    const pix: []u32 = @ptrCast(@alignCast(memoryRegion(self)));
    @memset(pix, 0);
}

fn fbMmap(_: *Framebuffer, map_unit: *sys.AddressSpace.MapUnit) vfs.Error!void {
    map_unit.ops = &map_unit_ops;
}

fn fbGetCapabilities(_: *Framebuffer, info: *Framebuffer.VariableScreenInfo) void {
    info.bits_per_pixel = @bitSizeOf(u32);
}

fn fbControl(_: *Framebuffer, info: *const Framebuffer.VariableScreenInfo) vfs.Error!void {
    log.info("set mode: {any}", .{info});
    return error.BadOperation;
}

fn mapUnitPageFault(map_unit: *sys.AddressSpace.MapUnit, pt: *vm.PageTable, _: usize, _: vm.FaultCause) vfs.Error!*vm.Page {
    const self: *Framebuffer = Framebuffer.fromFile(map_unit.file.?);
    const base_phys = vm.translateVirtToPhys(self.virt) orelse return error.NoMemory;

    const page = try map_unit.attachPage(.{
        .base = vm.bytesToPagesExact(base_phys) + map_unit.page_offset,
        .dim = .{ .rank = vm.pagesToRank(map_unit.page_capacity) },
    });

    map_unit.flags.map.cache = .write_combine;
    try pt.map(
        map_unit.base(),
        base_phys + (map_unit.page_offset * vm.page_size),
        map_unit.page_capacity,
        map_unit.flags.map,
    );

    return page;
}

fn mapUnitUnmapPage(map_unit: *const sys.AddressSpace.MapUnit, pt: *const vm.PageTable, page: vm.Page) void {
    const mut_pt: *vm.PageTable = @constCast(pt);
    mut_pt.unmap(map_unit.base() + page.getOffset(), map_unit.page_capacity);
}

inline fn memoryRegion(self: *Framebuffer) []u8 {
    const virt: [*]u8 = @ptrFromInt(self.virt);
    return virt[0..self.size];
}
