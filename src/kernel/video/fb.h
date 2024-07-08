#pragma once

#include "definitions.h"

enum ColorFormat {
    ARGB,
    ARBG,
    ABGR,
    ABRG,

    RGBA,
    RBGA,
    BGRA,
    BRGA,
};

struct Color {
    uint8_t r, g, b, a;

    Color() = default;
    Color(const uint8_t r, const uint8_t g, const uint8_t b, const uint8_t a = 255)
    : r(r), g(g), b(b), a(a)
    {}

    uint32_t pack(const ColorFormat format) const;
    static Color unpack(const ColorFormat format, const uint32_t color);
};

struct Framebuffer {
    uintptr_t base;
    uint32_t scanline;
    uint32_t width;
    uint32_t height;

    ColorFormat format;

    Framebuffer() = default;
    Framebuffer(
        const uintptr_t base,
        const uint32_t scanline,
        const uint32_t width,
        const uint32_t height,
        const ColorFormat format
    )
    :
    base(base), scanline(scanline),
    width(width), height(height),
    format(format)
    {};
};