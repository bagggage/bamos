// @noexport

//! # Video Terminal
//! 
//! Responsible for drawing text to the framebuffer,
//! handling cursor position and special characters.

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const cc = std.ascii.control_code;

const boot = @import("../boot.zig");
const config = utils.config;
const log = std.log.scoped(.@"video.terminal");
const utils = @import("../utils.zig");
const vm = @import("../vm.zig");

const Color = Framebuffer.Color;
const Framebuffer = @import("Framebuffer.zig");
const text_output = @import("text-output.zig");

const use_buffers = true;
const fb_display = "fb0";

const Cursor = struct {
    const tab_size = 6;

    row: u16,
    col: u16,

    /// Moves the cursor to the next row.
    /// If the cursor is already on the last row,
    /// it triggers a screen scroll.
    inline fn nextRow(self: *Cursor) void {
        if (self.row == rows - 1) {
            if (comptime use_buffers) scroll();
        } else {
            self.row += 1;
        }

        self.col = 0;
    }

    /// Moves the cursor to the right.
    inline fn right(self: *Cursor) void {
        self.col += 1;
        if (self.col == cols) self.nextRow();
    }

    /// Moves the cursor to the left.
    inline fn left(self: *Cursor) void {
        if (self.col == 0) {
            if (self.row != 0) {
                self.col = cols;
                self.row -= 1;
            }

            return;
        }

        self.col -= 1;
        if (self.col == cols) self.nextRow();
    }

    inline fn tab(self: *Cursor) void {
        const tabs_num = cols / tab_size;
        const curr_tab = self.col / tab_size;

        self.col = if (curr_tab + 1 >= tabs_num) (cols - 1) else (curr_tab + 1) * tab_size;
    }
};

var framebuffer: Framebuffer = undefined;
var cursor: Cursor = Cursor{ .col = 0, .row = 0 };

/// Number of columns on screen.
var cols: u16 = undefined;
/// Number of rows on screen.
var rows: u16 = undefined;
/// Current color value used for rendering text.
var curr_col: u32 = undefined;

/// Buffer storing the ascii characters.
var char_buffer: []u8 = undefined;
var char_buf_rank: u32 = undefined;

/// Buffer storing the color of each character.
var color_buffer: []u32 = undefined;
var color_buf_rank: u32 = undefined;

var is_initialized = false;

pub fn init() !void {
    const display = config.getAs(?[]const u8, "display") orelse fb_display;

    if (display) |disp| {
        if (std.mem.eql(u8, disp, fb_display) == false) {
            log.warn("unknown display: {s}: skip initialization", .{disp});
            return;
        }
    } else {
        log.warn("no display: skip initialization", .{});
        return;
    }

    boot.getFb(&framebuffer);

    try text_output.init(&framebuffer);
    errdefer text_output.deinit();

    curr_col = Color.lgray.pack(framebuffer.format);

    cols = @truncate(framebuffer.width / text_output.font.width);
    rows = @truncate(framebuffer.height / text_output.font.height);

    if (comptime use_buffers) {
        char_buffer.len = cols * rows;
        color_buffer.len = char_buffer.len;

        // Allocate characters buffer
        const buf_pages = std.math.divCeil(usize, char_buffer.len, vm.page_size) catch unreachable;
        char_buf_rank = std.math.log2_int_ceil(usize, buf_pages);
        const buf_phys = vm.PageAllocator.alloc(@truncate(char_buf_rank)) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(buf_phys, char_buf_rank);

        char_buffer.ptr = @ptrFromInt(vm.getVirtLma(buf_phys));
        @memset(char_buffer, 0);

        // Allocate color buffer
        const color_buf_pages = std.math.divCeil(usize, color_buffer.len * @sizeOf(u32), vm.page_size) catch unreachable;
        color_buf_rank = std.math.log2_int_ceil(usize, color_buf_pages);
        const color_buf_phys = vm.PageAllocator.alloc(@truncate(color_buf_rank)) orelse return error.NoMemory;

        color_buffer.ptr = @ptrFromInt(vm.getVirtLma(color_buf_phys));
        @memset(color_buffer, curr_col);
    }

    is_initialized = true;
}

pub fn deinit() void {
    if (comptime use_buffers == false) return;
    if (is_initialized == false) return;

    const char_buf_phys = vm.getPhysLma(char_buffer.ptr);
    const color_buf_phys = vm.getPhysLma(color_buffer.ptr);

    vm.PageAllocator.free(@intFromPtr(char_buf_phys), char_buf_rank);
    vm.PageAllocator.free(@intFromPtr(color_buf_phys), color_buf_rank);
}

pub inline fn isInitialized() bool {
    return is_initialized;
}

/// Sets the cursor position to the specified row and column.
pub inline fn setCursor(row: u16, col: u16) void {
    cursor.row = row % rows;
    cursor.col = col % cols;
}

/// Sets the current color used for text rendering.
pub inline fn setColor(color: Color) void {
    curr_col = color.pack(framebuffer.format);
}

pub inline fn getCursor() Cursor {
    return cursor;
}

/// Returns the current color used for text rendering.
pub inline fn getColor() Color {
    return Color.unpack(framebuffer.format, curr_col);
}

/// Writes the given string to the framebuffer.
/// Handles special characters and moves cursor.
pub fn write(str: []const u8) void {
    var i: u32 = 0;

    while (i < str.len) : (i += 1) {
        const char = str[i];

        if (char == cc.esc) {
            i += handleEscapeSequence(str[i..]) - 1;
        } else if (std.ascii.isControl(char)) {
            handleControlChar(char);
        } else if (std.ascii.isAscii(char)) {
            cacheChar(char);

            text_output.drawChar(char, curr_col, cursor.row, cursor.col);
            cursor.right();
        }
    }
}

inline fn cacheChar(char: u8) void {
    if (comptime use_buffers) {
        const idx = (cursor.row * cols) + cursor.col;

        color_buffer[idx] = curr_col;
        char_buffer[idx] = char;
    }
}

inline fn handleControlChar(char: u8) void {
    switch (char) {
        cc.cr => cursor.col = 0,
        cc.ht => cursor.tab(),
        cc.bs => cursor.left(),
        cc.lf,
        cc.vt,
        cc.ff => cursor.nextRow(),
        else => {}
    }
}

inline fn handleEscapeSequence(seq: []const u8) u32 {
    @setRuntimeSafety(false);

    if (seq.len < 3 or seq[1] != '[') return 1;

    var pos: u32 = 2;

    const len = std.mem.indexOf(u8, seq[2..], "m") orelse return pos;
    var iter = std.mem.splitAny(u8, seq[2..len + 3], ";m");

    while (iter.next()) |subseq| {
        const code = std.fmt.parseUnsigned(u8, subseq, 10) catch return pos;
        handleEscapeCode(code);

        pos += @truncate(subseq.len + 1);
    }

    return pos;
}

inline fn handleEscapeCode(code: u8) void {
    @setRuntimeSafety(false);

    if (code == 0) {
        setColor(Color.lgray);
        return;
    }

    // Handle colors
    if ((code >= 30 and code <= 37) or (code >= 40 and code <= 47)) {
        const color_idx = code % 10;
        const color = switch (color_idx) {
            0 => Color.black,
            1 => Color.red,
            2 => Color.green,
            3 => Color.yellow,
            4 => Color.blue,
            5 => Color.magenta,
            6 => Color.cyan,
            7 => Color.lgray,
            else => unreachable
        };

        if (code < 40) setColor(color);
    }
    else if ((code >= 90 and code <= 97) or (code >= 100 and code <= 107)) {
        const color_idx = code % 10;
        const color = switch (color_idx) {
            0 => Color.gray,
            1 => Color.lred,
            2 => Color.lgreen,
            3 => Color.lyellow,
            4 => Color.lblue,
            5 => Color.lmagenta,
            6 => Color.lcyan,
            7 => Color.white,
            else => unreachable
        };

        if (code < 100) setColor(color);
    }
}

/// Scrolls the text buffer up by one row, clearing the last row on the screen.
fn scroll() void {
    @setRuntimeSafety(false);

    const fb_size = (framebuffer.scanline * rows * text_output.font.height) * @sizeOf(u32);
    const row_size = (framebuffer.scanline * text_output.font.height) * @sizeOf(u32);

    var buf_offset: usize = 0;

    for (1..rows) |row| {
        buf_offset += cols;

        var col: u16 = 0;

        while (col < cols) : (col += 1) {
            const prev_offset = buf_offset - cols;
            const char = char_buffer[buf_offset + col];
            const color = color_buffer[buf_offset + col];

            if (char == 0) {
                var prev_c = char_buffer[prev_offset + col];

                while (prev_c != 0 and col < cols) : ({
                    col += 1; prev_c = char_buffer[prev_offset + col];
                }) {
                    char_buffer[prev_offset + col] = 0;
                    text_output.drawChar(' ', color, @truncate(row - 1), @truncate(col));
                }

                break;
            }

            char_buffer[prev_offset + col] = char;
            color_buffer[prev_offset + col] = color;

            text_output.drawChar(char, color, @truncate(row - 1), @truncate(col));
        }
    }

    // Cleanup last row
    for (0..cols) |i| {
        if (char_buffer[buf_offset + i] == 0) break;
        char_buffer[buf_offset + i] = 0;
    }

    fastMemset256(@intFromPtr(framebuffer.base) + fb_size - row_size, row_size, 0);
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

