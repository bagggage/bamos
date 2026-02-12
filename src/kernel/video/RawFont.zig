//! # Raw Font
//! 
//! Responsible for loading and processing
//! raw font data from PSF (PC Screen Font) files.
//! It supports both PSF1 and PSF2 font formats,
//! allowing for the extraction and use of glyphs in a text-rendering context.

const std = @import("std");
const assert = std.debug.assert;

/// Embedded font data from an external PSF file.
const font_data align(@alignOf(PSF2)) = @embedFile("fonts-bin/uni2-vga-8x16.psf");

const PSF1_MODE512 = 0x01;
const PSF1_MAGIC = 0x0436;
const PSF2_MAGIC = 0x864ab572;

const Self = @This();

/// Structure representing the PSF1 font header.
const PSF1 = packed struct {
    magic:  u16, // 0x0436
    flags:  u8,  // how many glyps and if unicode, etc.
    height: u8,  // height; width is always 8

    glyphs: u8
};

/// Structure representing the PSF2 font header.
const PSF2 = packed struct {
    magic:      u32, // 0x864ab572
    version:    u32,
    hdr_size:   u32, // offset of bitmaps in file
    flags:      u32,
    length:     u32, // number of glyphs
    charsize:   u32, // number of bytes for each character
    height:     u32, // dimensions of glyphs
    width:      u32,
    glyphs: u8
};

width: u8,
height: u8,
/// Number of bytes for each character glyph.
charsize: u32,

/// Slice pointing to the glyph data in memory.
glyphs: []const u8,

pub const default_font = fromData(font_data);

/// Initializes `RawFont` structure from the provided font data byte array,
/// determining if it's PSF1 or PSF2 format.
fn fromData(data: [*:0]const u8) Self {
    const psf1: *const PSF1 = @ptrCast(@alignCast(data));
    const psf2: *const PSF2 = @ptrCast(@alignCast(data));

    var result: @This() = undefined;

    if (psf1.magic == PSF1_MAGIC) {
        result.charsize = psf1.height;
        result.width = 8;
        result.height = psf1.height; 

        const length = if ((psf1.flags & PSF1_MODE512) != 0) 512 else 256;

        result.glyphs.len = result.charsize * length; 
        result.glyphs.ptr = @ptrCast(&psf1.glyphs);
    }
    else if (psf2.magic == PSF2_MAGIC) {
        result.charsize = psf2.charsize;
        result.width = psf2.width;
        result.height = psf2.height;

        result.glyphs.len = result.charsize * psf2.length;
        result.glyphs.ptr = @ptrCast(&psf2.glyphs);
    }
    else unreachable;

    return result;
}
