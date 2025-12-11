// @noexport

//! # Video Module
//! 
//! This module provides functionality related to video output, including text drawing.

pub const text_output = @import("video/text-output.zig");
pub const terminal = @import("video/terminal.zig");

pub const Framebuffer = @import("video/Framebuffer.zig");
pub const Color = Framebuffer.Color;
pub const RawFont = @import("video/RawFont.zig");

const boot = @import("boot.zig");

pub fn debugBlt(color: Color, offset: usize, len: usize) void {
    const fb_ptr: [*]u32 = @ptrCast(&boot.fb);
    @memset(fb_ptr[offset..offset + len], color.pack(.ARGB));
}
