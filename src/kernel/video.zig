//! # Video Module
//! This module provides functionality related to video output, including text drawing.

pub const text_output = @import("video/text-output.zig");

pub const Framebuffer = @import("video/Framebuffer.zig");
pub const Color = Framebuffer.Color;
pub const RawFont = @import("video/RawFont.zig");