#include "bootboot_display.h"

#include <bootboot.h>

extern BOOTBOOT bootboot; // see bootboot.h
extern uint32_t fb[];

Framebuffer display_fb;

#define BOOTBOOT_FB_BPP 4

Status init_bootboot_display(DisplayDevice* dev) {
    if (bootboot_display_is_avail() == FALSE) {
        return KERNEL_ERROR;
    }

    display_fb.base = (uint8_t*)fb;
    display_fb.width = bootboot.fb_width;
    display_fb.height = bootboot.fb_height;
    display_fb.scanline = bootboot.fb_scanline;
    display_fb.format = (FbFormat)bootboot.fb_type;
    display_fb.bpp = BOOTBOOT_FB_BPP;

    dev->fb = &display_fb;

    return KERNEL_OK;
}

bool_t bootboot_display_is_avail() {
    return (bootboot.fb_ptr != NULL && bootboot.fb_size != 0);
}