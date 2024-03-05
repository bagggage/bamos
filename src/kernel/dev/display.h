#pragma once

#include "definitions.h"
#include "device.h"

typedef enum FbFormat {
    FB_FORMAT_ARGB = 0,
    FB_FORMAT_RGBA = 1,
    FB_FORMAT_ABGR = 2,
    FB_FORMAT_BGRA = 3
} FbFormat;

typedef struct Framebuffer {
    uint8_t* base;
    uint32_t width;
    uint32_t height;
    uint8_t bpp; // Bytes per pixel
    uint32_t scanline; // Bytes per horizontal line
    FbFormat format;
} Framebuffer;

// TODO
typedef struct DisplayInterface {
} DisplayInterface;

// TODO
typedef struct DisplayDevice {
    DEVICE_STRUCT_IMPL(Display);
    Framebuffer* fb;
} DisplayDevice;