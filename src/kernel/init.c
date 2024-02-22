#include "init.h"

#include <bootboot.h>
#include <cpuid.h>

#include "dev/bootboot_display.h"
#include "dev/keyboard.h"
#include "dev/ps2_keyboard.h"
#include "io/logger.h"

#define CPUID_GET_FEATURE 1

#ifdef MEM_RAW_PATCH
Status init_memory() {
    return KERNEL_OK;
}
#endif

extern BOOTBOOT bootboot;
extern volatile unsigned char _binary_font_psf_start;

void halt_logical_core() {
    while (1);
}

void logical_core_delay(uint64_t idx) {
    uint64_t end_point = idx << 21;

    do {
        ++idx;
        __asm__ __volatile__("");
    } while (idx < end_point);
}

Status split_logical_cores() {
    uint32_t eax, ebx, ecx, edx;

    __get_cpuid(CPUID_GET_FEATURE, &eax, &ebx, &ecx, &edx);

    // Get logical core ID (31-24 bit)
    ebx = ebx >> 24;

    // Debug
    // Delay between output for different logical cores 
    logical_core_delay(ebx);

    if (is_logger_initialized() == FALSE) {
        if (init_kernel_logger_raw(&_binary_font_psf_start) != KERNEL_OK) {
            return KERNEL_PANIC;
        }
    }

    kernel_msg("CPU %u\n", ebx);

    // Only core with ID = 0 pass
    if (ebx != 0) halt_logical_core();

    logical_core_delay(32);
    kernel_msg("Kernel startup on CPU %u\n", ebx);

    return KERNEL_OK;
}

Status init_kernel() {
    if (split_logical_cores() != KERNEL_OK) return KERNEL_PANIC;

    // After this step we should be able to use memory allocations, otherwise drop kernel =)
    if (init_memory() != KERNEL_OK) return KERNEL_PANIC;

    Status status = init_io_devices();

    if (status != KERNEL_OK) return status;

    status |= init_io_streams();

    return status;
}

Status init_io_devices() {
    // TODO
    DisplayDevice* display;
    KeyboardDevice* keyboard;

    if (add_device(DEV_DISPLAY, &display, sizeof(DisplayDevice)) != KERNEL_OK) return KERNEL_ERROR;
    if (init_bootboot_display(display) != KERNEL_OK) return KERNEL_ERROR;

    if (add_device(DEV_KEYBOARD, &keyboard, sizeof(KeyboardDevice)) != KERNEL_OK) return KERNEL_ERROR;
    if (init_ps2_keyboard(keyboard) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_io_streams() {
    // TODO

    return KERNEL_OK;
}