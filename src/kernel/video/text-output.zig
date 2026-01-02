// @noexport

//! # Simple Text Output
//! 
//! Responsible for rendering text and characters using a `RawFont` to framebuffer.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const boot = @import("../boot.zig");
const vm = @import("../vm.zig");

const Framebuffer = @import("Framebuffer.zig");
const RawFont = @import("RawFont.zig");

pub const font: RawFont = RawFont.default_font;

const use_texture = true;

var fb: *Framebuffer = undefined;

/// Texture buffer for rendering the font glyphs.
var font_tex: []u32 = undefined;
var font_tex_rank: u8 = undefined;

/// Initializes the text output system,
/// setting up the framebuffer, ascii buffers, and rendering the font.
/// 
/// This function should be called only once.
pub fn init(framebuffer: *Framebuffer) !void {
    fb = framebuffer;

    if (comptime use_texture) {
        font_tex.len = (font.glyphs.len / font.charsize) * (font.height * font.width);

        const font_tex_pages = std.math.divCeil(usize, font_tex.len * @sizeOf(u32), vm.page_size) catch unreachable;
        font_tex_rank = std.math.log2_int_ceil(usize, font_tex_pages);
        const phys = vm.PageAllocator.alloc(@truncate(font_tex_rank)) orelse return error.NoMemory;

        font_tex.ptr = @ptrFromInt(vm.getVirtLma(phys));
        renderFont(font_tex);
    }
}

pub fn deinit() void {
    if (comptime use_texture == false) return;

    vm.PageAllocator.free(vm.getPhysLma(font_tex.ptr), font_tex_rank);
}

/// Draws a single character at the specified row and column using the current color.
pub const drawChar: fn(char: u8, color: u32, row: u16, col: u16) void = if (use_texture) drawCharTextured else drawCharRendered;

fn drawCharTextured(char: u8, color: u32, row: u16, col: u16) void {
    @setRuntimeSafety(false);

    if (char == 0) { @branchHint(.unlikely); return; }

    const ColorVec = @Vector(font.width, u32);

    const char_size = font.width * font.height;
    const offset = (row * fb.scanline * font.height) + (col * font.width);

    const color_arr = .{color} ** font.width;
    const color_vec: ColorVec = color_arr;

    var dest: *ColorVec = @ptrFromInt(@intFromPtr(fb.base) + (offset * @sizeOf(u32)));
    const glyph: [*]const ColorVec = @ptrFromInt(@intFromPtr(font_tex.ptr) + (@as(usize, char) * char_size * @sizeOf(u32)));

    for (0..font.height) |y| {
        dest.* = glyph[y] & color_vec;

        dest = @ptrFromInt(@intFromPtr(dest) + (fb.scanline * @sizeOf(u32)));
    }
}

fn drawCharRendered(char: u8, color: u32, row: u16, col: u16) void {
    @setRuntimeSafety(false);

    if (char == 0) return;

    const offset = (row * fb.scanline * font.height) + (col * font.width);

    renderChar(char, fb.base[offset..], color, fb.scanline);
}

/// Renders the font into a texture buffer for fast character drawing.
fn renderFont(texture: []u32) void {
    @branchHint(.cold);

    var offset: u32 = 0;
    const char_num = font.glyphs.len / font.charsize;

    for (0..char_num) |c| {
        renderChar(@truncate(c), texture[offset..].ptr, 0xFFFFFFFF, font.width);
        offset += font.width * font.height;
    }
}

fn renderChar(char: u16, buffer: [*]u32, color: u32, v_step: u32) void {
    @setRuntimeSafety(false);

    var offset: u32 = 0;

    const glyph_ptr: [*]const u8 = @ptrCast(&font.glyphs[char * font.charsize]);
    const glyph: []const u8 = glyph_ptr[0..font.charsize];

    for (0..font.height) |y| {
        var bitmask: u8 = @as(u8, 1) << @truncate(font.width - 1);

        for (0..font.width) |x| {
            buffer[offset + x] = if ((glyph[y] & bitmask) != 0) color else 0;
            bitmask >>= 1;
        }

        offset += v_step;
    }
}