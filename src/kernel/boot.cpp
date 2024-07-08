#include "boot.h"

#include <bootboot.h>

#include "trace.h"

#include "video/fb.h"

extern BOOTBOOT bootboot;

ColorFormat bootboot_make_color_fmt(const uint8_t fb_type) {
    switch (fb_type)
    {
    case FB_ABGR: return ABGR;
    case FB_ARGB: return ARGB;
    case FB_BGRA: return BGRA;
    case FB_RGBA: return RGBA;
    default:
        break;
    }

    return RGBA;
}

void Boot::get_fb(Framebuffer* const fb) {
    *fb = Framebuffer(
        bootboot.fb_ptr,
        bootboot.fb_scanline,
        bootboot.fb_width,
        bootboot.fb_height,
        bootboot_make_color_fmt(bootboot.fb_type)
    );
}

uint32_t Boot::get_cpus_num() {
    return bootboot.numcores;
}

const DebugSymbolTable* Boot::get_dbg_table() {
    static constexpr unsigned char sym_table_magic[] = { 0xAC, 'D', 'B', 'G' };
    static constexpr uint32_t second_part_magic = 0xFE015223;

    const uint8_t* ptr = reinterpret_cast<uint8_t*>(bootboot.initrd_ptr);

    while (reinterpret_cast<uintptr_t>(ptr) < bootboot.initrd_ptr + bootboot.initrd_size) {
        if (*(const uint32_t*)ptr == *(const uint32_t*)sym_table_magic) {
            if (*(const uint32_t*)(ptr + sizeof(uint32_t)) == second_part_magic) {
                return reinterpret_cast<const DebugSymbolTable*>(ptr);
            }
        }

        ptr++;
    }

    return nullptr;
}