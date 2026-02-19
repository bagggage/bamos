//! # Video Terminal
//! 
//! Responsible for drawing text to the framebuffer,
//! handling cursor position and special characters.

// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const cc = std.ascii.control_code;

const boot = @import("../boot.zig");
const config = @import("../config.zig");
const log = std.log.scoped(.@"video.terminal");
const lib = @import("../lib.zig");
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

    /// Current color value used for rendering text.
    color: u32,

    /// Moves the cursor to the next row.
    /// If the cursor is already on the last row,
    /// it triggers a screen scroll.
    fn nextRow(self: *Cursor) void {
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
    fn left(self: *Cursor) void {
        if (self.col == 0) {
            if (self.row != 0) {
                self.col = cols - 1;
                self.row -= 1;
            }

            return;
        }

        self.col -= 1;
    }

    fn tab(self: *Cursor) void {
        const tabs_num = cols / tab_size;
        const curr_tab = self.col / tab_size;

        self.col = if (curr_tab + 1 >= tabs_num) (cols - 1) else (curr_tab + 1) * tab_size;
    }

    fn blink(self: *Cursor) void {
        if (!cursor_blink) setBlink(self.row, self.col) else clearBlink();
    }
};

var framebuffer: Framebuffer = undefined;
var cursor: Cursor = .{ .col = 0, .row = 0, .color = 0 };

var blink_pos: [2]u16 = .{ 0, 0 };
var blink_enable: std.atomic.Value(bool) = .init(true);
var cursor_blink: bool = false;

/// Number of columns on screen.
var cols: u16 = undefined;
/// Number of rows on screen.
var rows: u16 = undefined;

/// Buffer storing the ascii characters.
var char_buffer: []u8 = undefined;
/// Buffer storing the color of each character.
var color_buffer: []u32 = undefined;

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

    cursor.color = Color.lgray.pack(framebuffer.format);

    cols = @truncate(framebuffer.width / text_output.font.width);
    rows = @truncate(framebuffer.height / text_output.font.height);

    if (comptime use_buffers) {
        char_buffer.len = cols * rows;
        color_buffer.len = char_buffer.len;


        // Allocate characters buffer
        const char_buffer_rank = vm.bytesToRank(char_buffer.len);
        const buf_phys = vm.PageAllocator.alloc(char_buffer_rank) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(buf_phys, char_buffer_rank);

        // Allocate color buffer
        const color_buffer_rank = vm.bytesToRank(color_buffer.len * @sizeOf(u32));
        const color_buf_phys = vm.PageAllocator.alloc(color_buffer_rank) orelse return error.NoMemory;

        char_buffer.ptr = @ptrFromInt(vm.getVirtLma(buf_phys));
        color_buffer.ptr = @ptrFromInt(vm.getVirtLma(color_buf_phys));

        @memset(char_buffer, 0);
        @memset(color_buffer, cursor.color);
    }

    is_initialized = true;
}

pub fn deinit() void {
    if (comptime use_buffers == false) return;
    if (is_initialized == false) return;

    const char_buf_phys = vm.getPhysLma(char_buffer.ptr);
    const color_buf_phys = vm.getPhysLma(color_buffer.ptr);

    vm.PageAllocator.free(char_buf_phys, vm.bytesToRank(char_buffer.len));
    vm.PageAllocator.free(color_buf_phys, vm.bytesToRank(color_buffer.len * @sizeOf(u32)));
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
    cursor.color = color.pack(framebuffer.format);
}

pub fn setSize(size: [2]u16) !void {
    const max_rows = framebuffer.height / text_output.font.height;
    const max_cols = framebuffer.width / text_output.font.width;

    if (size[0] > max_rows or size[1] > max_cols) return error.MaxSize;

    rows = size[0];
    cols = size[1];
}

pub inline fn getCursor() Cursor {
    return cursor;
}

/// Returns the current color used for text rendering.
pub inline fn getColor() Color {
    return .unpack(framebuffer.format, cursor.color);
}

pub inline fn getSize() [2]u16 {
    return .{ rows, cols };
}

/// Writes the given string to the framebuffer.
/// Handles special characters and moves cursor.
pub fn write(str: []const u8) void {
    blink_enable.store(false, .release);
    if (cursor_blink) clearBlink();
    defer {
        setBlink(cursor.row, cursor.col);
        blink_enable.store(true, .release);
    }

    var i: u32 = 0;
    while (i < str.len) : (i += 1) {
        const char = str[i];

        if (char == cc.esc) {
            i += handleEscapeSequence(str[i + 1..]);
        } else if (std.ascii.isControl(char)) {
            handleControlChar(char);
        } else if (std.ascii.isAscii(char)) {
            cacheChar(char);

            text_output.drawChar(char, cursor.color, cursor.row, cursor.col);
            cursor.right();
        }
    }
}

pub inline fn blinkCursor() void {
    if (blink_enable.load(.acquire) == false) return;
    cursor.blink();
}

pub fn clear() void {
    @memset(char_buffer, 0);

    for (0..rows) |row| text_output.fillRow(@truncate(row), 0, cols, 0);
}

pub fn clearAt(row: u16, col: u16, n: u16) void {
    const pos = row * cols + col;
    @memset(char_buffer[pos..pos + n], 0);

    text_output.fillRow(row, col, n, 0);
}

inline fn cacheChar(char: u8) void {
    if (comptime use_buffers) {
        const idx = (cursor.row * cols) + cursor.col;

        color_buffer[idx] = cursor.color;
        char_buffer[idx] = char;
    }
}

inline fn cacheTab(old_col: u16) void {
    const row_pos = cursor.row * cols;

    for (old_col..cursor.col) |i| {
        color_buffer[row_pos + i] = cursor.color;
        char_buffer[row_pos + i] = ' ';
    }
}

fn setBlink(row: u16, col: u16) void {
    blink_pos = .{ row, col };
    cursor_blink = true;
    text_output.blink(row, col);
}

fn clearBlink() void {
    text_output.blink(blink_pos[0], blink_pos[1]);
    cursor_blink = false;
}

inline fn handleControlChar(char: u8) void {
    switch (char) {
        cc.cr => cursor.col = 0,
        cc.ht => {
            const old_col = cursor.col;
            cursor.tab();

            cacheTab(old_col);
        },
        cc.bs => cursor.left(),
        cc.lf,
        cc.vt,
        cc.ff => cursor.nextRow(),
        else => {}
    }
}

fn handleEscapeSequence(seq: []const u8) u32 {
    if (seq.len < 2 or seq[0] != '[') return 1;

    const end = blk: {
        var i: u32 = 0;
        while (i < seq.len) : (i += 1) {
            if (std.ascii.isAlphabetic(seq[i])) break :blk i;
        }
        return @truncate(seq.len);
    };

    switch (seq[end]) {
        'A' => { // Move up
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.row -|= n;
        },
        'B',
        'e' => { // Move down
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.row = @min(cursor.row + n, rows - 1);
        },
        'C',
        'a' => { // Move right
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.col -|= n;
        },
        'D' => { // Move left
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.col = @min(cursor.col + n, cols - 1);
        },
        'E' => { // Move down-right
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.row = @min(cursor.row + n, rows - 1);
        },
        'F' => { // Move up-right
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch 1;
            cursor.row -|= n;
            cursor.col = 0;
        },
        'G' => { // Set column
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch cursor.col;
            cursor.col = @min(n -| 1, cols - 1);
        },
        'H',
        'f' => { // Set row, column
            var delim = std.mem.splitScalar(u8, seq[1..end], ';');
            const row_str = delim.first();
            const col_str = delim.rest();
            const row = std.fmt.parseUnsigned(u16, row_str, 10) catch cursor.row;
            const col = std.fmt.parseUnsigned(u16, col_str, 10) catch cursor.col;

            cursor.row = @min(row -| 1, rows - 1);
            cursor.col = @min(col -| 1, cols - 1);
        },
        'J' => { // Erase display
            if (end == 1) {
                clearAt(cursor.row, cursor.col, cols - cursor.col);
                for (cursor.row..rows) |r| clearAt(@truncate(r), 0, cols);
            } else if (end == 2) switch (seq[1]) {
                '1' => {
                    for (0..cursor.row) |r| clearAt(@truncate(r), 0, cols);
                    clearAt(cursor.row, 0, cursor.col);
                },
                '2',
                '3' => clear(),
                else => {}
            };
        },
        'K' => { // Erase line
            if (end == 1) {
                clearAt(cursor.row, cursor.col, cols - cursor.col);
            } else if (end == 2) switch (seq[1]) {
                '1' => clearAt(cursor.row, 0, cursor.col),
                '2' => clearAt(cursor.row, 0, cols),
                else => {}
            };
        },
        'd' => { // Set row
            const n = std.fmt.parseUnsigned(u16, seq[1..end], 10) catch cursor.row;
            cursor.row = @min(n -| 1, rows - 1);
        },
        'm' => { // Set attributes
            var iter = std.mem.splitScalar(u8, seq[1..end], ';');
            while (iter.next()) |subseq| {
                const code = std.fmt.parseUnsigned(u8, subseq, 10) catch break;
                handleSetAttribute(code);
            }
        },
        else => {}
    }

    return end + 1;
}

inline fn handleSetAttribute(code: u8) void {
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

    text_output.fillRow(rows - 1, 0, cols, 0);
}
