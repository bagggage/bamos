//! # Text Output Module
//! Responsible for managing and rendering text output to the framebuffer,
//! handling cursor position, and rendering characters using a `comptime` font.

const std = @import("std");
const builtin = @import("builtin");

const boot = @import("../boot.zig");
const log = @import("../log.zig");
const serial = @import("../dev/drivers/uart.zig");
const vm = @import("../vm.zig");

const Framebuffer = @import("Framebuffer.zig");
const Color = Framebuffer.Color;
const RawFont = @import("RawFont.zig");

const Cursor = struct {
    row: u16,
    col: u16,

    /// Moves the cursor to the next row.
    /// If the cursor is already on the last row,
    /// it triggers a screen scroll.
    inline fn nextRow(self: *Cursor) void {
        if (self.row == rows - 1) {
            scroll();
        } else {
            self.row += 1;
        }

        self.col = 0;
    }
};

var fb: Framebuffer = undefined;
const font: RawFont = RawFont.default_font;

var cursor: Cursor = Cursor{ .col = 0, .row = 0 };

/// Number of columns on screen.
var cols: u16 = undefined;
/// Number of rows on screen.
var rows: u16 = undefined;

// Current color value used for rendering text.
var curr_col: u32 = undefined;

/// Texture buffer for rendering the font glyphs.
var font_tex: []u32 = undefined;
/// Buffer storing the ascii characters.
var buffer: []u8 = undefined;
/// Buffer storing the color of each character.
var color_buf: []u32 = undefined;

var is_initialized = false;

/// Initializes the text output system,
/// setting up the framebuffer, ascii buffers, and rendering the font.
/// 
/// This function should be called only once.
pub fn init() void {
    @setCold(true);

    boot.getFb(&fb);

    cols = @truncate(fb.width / font.width);
    rows = @truncate(fb.height / font.height);
    curr_col = Color.lgray.pack(fb.format);

    buffer.len = cols * rows;
    color_buf.len = buffer.len;

    const buf_pages = std.math.divCeil(usize, buffer.len, vm.page_size) catch unreachable;
    const buf_addr = boot.alloc(@truncate(buf_pages)) orelse unreachable;
    buffer.ptr = @ptrFromInt(vm.getVirtLma(buf_addr));
    @memset(buffer, 0);

    const color_buf_pages = std.math.divCeil(usize, color_buf.len * @sizeOf(u32), vm.page_size) catch unreachable;
    const color_buf_addr = boot.alloc(@truncate(color_buf_pages)) orelse unreachable;
    color_buf.ptr = @ptrFromInt(vm.getVirtLma(color_buf_addr));
    @memset(color_buf, curr_col);

    font_tex.len = (font.glyphs.len / font.charsize) * (font.height * font.width);
    const texture_pages = std.math.divCeil(usize, font_tex.len * @sizeOf(u32), vm.page_size) catch unreachable;
    const texture_addr = boot.alloc(@truncate(texture_pages)) orelse unreachable;

    font_tex.ptr = @ptrFromInt(vm.getVirtLma(texture_addr));
    renderFont(font_tex);

    is_initialized = true;
}

/// Checks if the text output system is initialized.
pub inline fn isEnabled() bool {
    return is_initialized;
}

/// Sets the cursor position to the specified row and column.
pub inline fn setCursor(row: u16, col: u16) void {
    cursor.row = row % rows;
    cursor.col = col % cols;
}

/// Sets the current color used for text rendering.
pub inline fn setColor(color: Color) void {
    curr_col = color.pack(fb.format);
}

/// Returns the current color used for text rendering.
pub inline fn getColor() Color {
    return Color.unpack(fb.format, curr_col);
}

/// Prints the given string to the framebuffer.
/// Handles newline characters by moving to the next row.
pub fn print(str: []const u8) void {
    for (str) |char| {
        if (char == 0) return;

        const idx = (cursor.row * cols) + cursor.col;

        color_buf[idx] = curr_col;
        buffer[idx] = char;

        if (char == '\n') {
            serial.write("\r\n");

            cursor.nextRow();
            continue;
        }

        serial.put(char);

        drawChar(char, cursor.row, cursor.col);

        cursor.col += 1;
        if (cursor.col == cols) cursor.nextRow();
    }
}

/// Draws a single character at the specified row and column using the current color.
fn drawChar(char: u8, row: u16, col: u16) void {
    @setCold(false);
    @setRuntimeSafety(false);

    if (char == 0) return;

    const ColorVec = @Vector(font.width, u32);

    const char_size = font.width * font.height;
    const offset = (row * fb.scanline * font.height) + (col * font.width);

    const color_arr = .{curr_col} ** font.width;
    const color: ColorVec = color_arr;

    var dest: *ColorVec = @ptrFromInt(@intFromPtr(fb.base) + (offset * @sizeOf(u32)));
    const glyph: [*]const ColorVec = @ptrFromInt(@intFromPtr(font_tex.ptr) + (@as(usize, char) * char_size * @sizeOf(u32)));

    for (0..font.height) |y| {
        dest.* = glyph[y] & color;

        dest = @ptrFromInt(@intFromPtr(dest) + (fb.scanline * @sizeOf(u32)));
    }
}

/// Renders the font into a texture buffer for fast character drawing.
fn renderFont(texture: []u32) void {
    @setCold(true);

    var offset: u32 = 0;
    const char_num = font.glyphs.len / font.charsize;

    for (0..char_num) |c| {
        const glyph_ptr: [*]const u8 = @ptrCast(&font.glyphs[c * font.charsize]);
        const glyph: []const u8 = glyph_ptr[0..font.charsize];

        for (0..font.height) |y| {
            var bitmask: u8 = @as(u8, 1) << @truncate(font.width - 1);

            for (0..font.width) |x| {
                texture[offset + x] = if ((glyph[y] & bitmask) != 0) 0xFFFFFFFF else 0;
                bitmask >>= 1;
            }

            offset += font.width;
        }
    }
}

/// Scrolls the text buffer up by one row, clearing the last row on the screen.
fn scroll() void {
    @setRuntimeSafety(false);

    const fb_size = (fb.scanline * rows * font.height) * @sizeOf(u32);
    const row_size = (fb.scanline * font.height) * @sizeOf(u32);

    var buf_offset: usize = 0;

    for (1..rows) |row| {
        buf_offset += cols;

        var col: u16 = 0;

        while (col < cols) : (col += 1) {
            const prev_offset = buf_offset - cols;
            const c = buffer[buf_offset + col];

            if (c == '\n' or c == 0) {
                var prev_c = buffer[prev_offset + col];

                while (prev_c != 0 and prev_c != '\n' and col < cols) {
                    drawChar(' ', @truncate(row - 1), @truncate(col));
                    buffer[prev_offset + col] = 0;

                    col += 1;
                    prev_c = buffer[prev_offset + col];
                }

                break;
            }

            curr_col = color_buf[buf_offset + col];

            buffer[prev_offset + col] = c;
            color_buf[prev_offset + col] = curr_col;

            drawChar(c, @truncate(row - 1), @truncate(col));
        }
    }

    fastMemset256(@intFromPtr(fb.base) + fb_size - row_size, row_size, 0);
}

const vec256_len = 256 / @sizeOf(u32);
const Vec256 = @Vector(vec256_len, u32);

/// Fast memory set operation using 256-bit vectorized instructions.
fn fastMemset256(dest_addr: usize, size: usize, value: u32) void {
    const val_arr = .{value} ** vec256_len;
    const vec_val: Vec256 = val_arr;

    const dest: [*]Vec256 = @ptrFromInt(dest_addr);
    const iters = size / vec256_len;

    for (0..iters) |i| {
        dest[i] = vec_val;
    }
}
