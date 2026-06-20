//! # Framebuffer device

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../../bindings.zig");
const devfs = vfs.devfs;
const lib = @import("../../lib.zig");
const sys = @import("../../sys.zig");
const video = @import("../../video.zig");
const vfs = @import("../../vfs.zig");

const Self = @This();

pub const IoCtl = enum(u32) {
    const Rop = enum(u8) { copy = 0, xor = 1 };

    pub const Rect = extern struct {
        dx: u32,
        dy: u32,
        width: u32,
        height: u32,
    };

    pub const CopyArea = extern struct {
        rect: Rect,
        sx: u32,
        sy: u32,
    };

    pub const FillRect = extern struct {
        rect: Rect,
        color: u32,
        rop: Rop,
    };

    pub const Image = extern struct {
        rect: Rect,
        fg_color: u32,
        bg_color: u32,
        depth: u8,

        data: [*]const u8,
        color_map: ColorMap,
    };

    pub const Vblank = extern struct {
        flags: u32,
        count: u32,
        v_count: u32,
        h_count: u32,
        _reserved: [4]u32,
    };

    pub const Cursor = extern struct {
        const Pos = extern struct { x: u16, y: u16 };
        const Set = packed struct(u16) {
            image: bool = false,
            pos: bool = false,
            hot: bool = false,
            color_map: bool = false,
            shape: bool = false,
            size: bool = false,

            _reserved: u10 = 0,
        };

        set: Set,
        enable: u16,
        rop: Rop,

        mask: *const u8,
        hot: Pos,
        image: Image,
    };

    get_vscreen_info = 0x4600,
    put_vscreen_info = 0x4601,
    get_fscreen_info = 0x4602,
    get_color_map    = 0x4604,
    put_color_map    = 0x4605,
    pan_display      = 0x4606,
    cursor           = 0x4608 | (@as(u32, 0x3) << 30) | (@as(u32, @sizeOf(Cursor)) << 16),

    get_con2fbmap    = 0x460f,
    put_con2fbmap    = 0x4610,
    blank            = 0x4611,
    get_vblank       = 0x4612 | (@as(u32, 0x2) << 30) | (@as(u32, @sizeOf(Vblank)) << 16),
    alloc            = 0x4613,
    free             = 0x4614,
    glyph            = 0x4615,
    hwc_info         = 0x4616,
    mode_info        = 0x4617,
    display_info     = 0x4618,
    wait_for_vsync   = 0x4620 | (@as(u32, 0x1) << 30) | (@as(u32, @sizeOf(u32)) << 16),
};

pub const Type = enum(u32) {
    packed_pixels      = 0,
    planes             = 1,
    interleaved_planes = 2,
    text               = 3,
    vga_planes         = 4,
    fourcc             = 5,
};

pub const Visual = enum(u32) {
    mono01              = 0,
    mono10              = 1,
    true_color          = 2,
    pseudo_color        = 3,
    direct_color        = 4,
    static_pseudo_color = 5,
    fourcc              = 6,
};

pub const Activate = packed struct(u32) {
    next_open: bool = false,
    @"test": bool = false,

    _reserved: u2 = 0,

    vbl: bool = false,
    cmap_vbl: bool = false,
    all: bool = false,
    force: bool = false,
    kd_text: bool = false,

    _reserved1: u23 = 0,
};

pub const Sync = packed struct(u32) {
    horizontal_high: bool = false,
    vertical_high: bool = false,
    external: bool = false,
    compositive_high: bool = false,
    broadcast: bool = false,
    on_green: bool = false,

    _reserved: u26 = 0,
};

pub const Vmode = packed struct(u32) {
    interlaced: bool = false,
    double: bool = false,
    top_line_first: bool = false,

    _reserved: u29 = 0,
};

pub const Rotate = enum(u8) {
    ur = 0,
    cw = 1,
    ud = 2,
    ccw = 3,
};

pub const aux = opaque {
    pub const Text = enum(u8) {
        mda         = 0,
        cga         = 1,
        s3_mmio     = 2,
        mga_step16  = 3,
        mga_step8   = 4,
        svga_mask   = 7,
        svga_step2  = 8,
        svga_step4  = 9,
        svga_step8  = 10,
        svga_step16 = 11,
    };

    pub const VgaPlanes = enum(u8) {
        vga4 = 0,
        cfb4 = 1,
        cfb8 = 2,
    };
};

pub const Capabilities = packed struct(u32) {
    fourcc: bool = false,
    _reserved: u31 = 0,
};

pub const ColorMap = extern struct {
    start: u32,
    len: u32,

    red: *u16,
    green: *u16,
    blue: *u16,
    transp: *u16,
};

pub const BitField = extern struct {
    offset: u32,
    length: u32,
    msb_right: u32 = 0,
};

pub const FixedScreenInfo = extern struct {
    id: [16]u8 = undefined,
    smem_phys: usize = 0,
    smem_len: u32,
    type: Type,
    type_aux: u32,
    visual: Visual,

    x_pan_step: u16,
    y_pan_step: u16,
    y_wrap_step: u16,
    line_len: u32,

    mmio_phys: usize = 0,
    mmio_len: u32 = 0,
    accel: u32 = 0,

    capabilities: Capabilities = .{},
    _reserved: u16 = undefined,
};

pub const VariableScreenInfo = extern struct {
    x_res: u32,
    y_res: u32,
    x_res_virt: u32,
    y_res_virt: u32,
    x_offset: u32,
    y_offset: u32,
    bits_per_pixel: u32,
    grayscale: bool = false,

    red:    BitField,
    green:  BitField,
    blue:   BitField,
    transp: BitField,

    non_std: bool = false,
    activate: Activate,

    height_mm: u32,
    width_mm: u32,

    accel_flags: u32 = 0,

    pix_clock_ps: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: Sync,
    vmode: Vmode,
    rotate: u32,
    color_space: u32,

    _reserved: [4]u32 = undefined,
};

pub const Operations = struct {
    pub const ReadFn = *const fn (*Self, usize, []u8) usize;
    pub const WriteFn = *const fn (*Self, usize, []const u8) usize;
    pub const FillRectFn = *const fn (*Self, *const IoCtl.FillRect) void;
    pub const CopyAreaFn = *const fn (*Self, *const IoCtl.CopyArea) void;
    pub const ImageBlitFn = *const fn (*Self, *const IoCtl.Image) void;
    pub const BlankFn = *const fn (*Self) void;
    pub const MmapFn = *const fn (*Self, *sys.AddressSpace.MapUnit) vfs.Error!void;
    pub const GetCapabilitiesFn = *const fn (*Self, *VariableScreenInfo) void;
    pub const ControlFn = *const fn (*Self, *const VariableScreenInfo) vfs.Error!void;

    read: ?ReadFn = null,
    write: ?WriteFn = null,

    fill_rect: FillRectFn,
    copy_area: CopyAreaFn,
    image_blit: ImageBlitFn,
    blank: BlankFn,

    mmap: MmapFn,

    get_capabilities: GetCapabilitiesFn,
    control: ControlFn,
};

id: []const u8,
ops: *const Operations,
dev_file: devfs.DevFile,

width: u16,
height: u16,
scanline: u32,
format: video.Color.Format,

virt: usize,
phys: usize,
size: u32,

pub inline fn setup(
    self: *Self,
    id: []const u8,
    ops: *const Operations,
    width: u16,
    height: u16,
    scanline: u32,
    format: video.Color.Format,
    virt: usize,
    phys: usize,
    size: u32,
) vfs.Error!void {
    return bindings.getInstance().dev.classes.framebuffer.setup(
        self,
        id,
        ops,
        width,
        height,
        scanline,
        format,
        virt,
        phys,
        size,
    );
}

pub inline fn fromFile(file: *vfs.File) *Self {
    return file.data.asPtr(Self).?;
}

pub inline fn fromDevFile(dev_file: *devfs.DevFile) *Self {
    return @fieldParentPtr("dev_file", dev_file);
}
