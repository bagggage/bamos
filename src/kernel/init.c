#include "init.h"

#include <bootboot.h>

#include "dev/bootboot_display.h"
#include "dev/keyboard.h"
#include "io/logger.h"

#ifdef MEM_RAW_PATCH
Status init_memory() {
    return KERNEL_OK;
}
#endif

Status init_kernel() {
    // After this step we should be able to use memory allocations, otherwise drop kernel =)
    if (init_memory() != KERNEL_OK) return KERNEL_PANIC;

    Status status = init_io_devices();

    if (status != KERNEL_OK) return status;

    status |= init_io_streams();

    return status;
}

extern volatile unsigned char _binary_font_psf_start;

Status init_io_devices() {
    // TODO
    DisplayDevice* display;

    if (add_device(DEV_DISPLAY, &display, sizeof(DisplayDevice)) != KERNEL_OK) return KERNEL_ERROR;
    if (init_bootboot_display(display) != KERNEL_OK) return KERNEL_ERROR;

    return init_kernel_logger(display->fb, &_binary_font_psf_start);
}

Status init_io_streams() {
    // TODO

    return KERNEL_OK;
}