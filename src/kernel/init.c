#include "init.h"

#include <bootboot.h>
#include <cpuid.h>
#include <stddef.h>

#include "dev/acpi_timer.h"
#include "dev/bootboot_display.h"
#include "dev/hpet_timer.h"
#include "dev/keyboard.h"
#include "dev/ps2_keyboard.h"
#include "dev/stds/acpi.h"
#include "dev/stds/ahci.h"

#include "logger.h"
#include "mem.h"

#include "intr/apic.h"
#include "intr/intr.h"
#include "intr/ioapic.h"


#define CPUID_GET_FEATURE 1

extern BOOTBOOT bootboot;
extern const uint8_t _binary_font_psf_start;

static void halt_logical_core() {
    while (1);
}

static Status split_logical_cores() {
    uint32_t eax, ebx = 0, ecx, edx;

    __get_cpuid(CPUID_GET_FEATURE, &eax, &ebx, &ecx, &edx);

    // Get logical core ID (31-24 bit)
    ebx = ebx >> 24;

    if (ebx != 0) halt_logical_core();
    if (init_kernel_logger_raw(&_binary_font_psf_start) != KERNEL_OK) return KERNEL_PANIC;

    kernel_msg("Kernel startup on CPU %u\n", ebx);

    return KERNEL_OK;
}

extern uint32_t fb[];

static Status init_timer() {
    if (is_acpi_timer_avail() == FALSE) {
        error_str = "There is no supported timer device";
        return KERNEL_ERROR;
    }

    TimerDevice* acpi_timer;

    if (add_device(DEV_TIMER, (void**)&acpi_timer, sizeof(TimerDevice)) != KERNEL_OK) return KERNEL_ERROR;
    if (init_acpi_timer(acpi_timer) != KERNEL_OK) return KERNEL_ERROR;

    //if (is_hpet_timer_avail() == FALSE) {
    //    error_str = "There is no supported timer device";
    //    return KERNEL_ERROR;
    //}
    //
    //TimerDevice* timer;
    //
    //if (add_device(DEV_TIMER, &timer, sizeof(TimerDevice)) != KERNEL_OK) return KERNEL_ERROR;
    //if (init_hpet_timer(timer) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_kernel() {
    if (split_logical_cores() != KERNEL_OK) return KERNEL_PANIC;
    // After this step we should be able to use memory allocations, otherwise drop kernel =)
    if (init_memory() != KERNEL_OK) return KERNEL_PANIC;
    if (init_intr() != KERNEL_OK) return KERNEL_PANIC;
    if (init_acpi() != KERNEL_OK) return KERNEL_ERROR;
    if (init_apic() != KERNEL_OK) return KERNEL_ERROR;
    if (init_ioapic() != KERNEL_OK) return KERNEL_ERROR;
    if (init_io_devices() != KERNEL_OK) return KERNEL_ERROR;
    if (init_timer() != KERNEL_OK) return KERNEL_ERROR;
    if (init_ahci() != KERNEL_OK) return KERNEL_ERROR;
    
    return KERNEL_OK;
}

Status init_io_devices() {
    // TODO
    DisplayDevice* display;
    //KeyboardDevice* keyboard;

    if (add_device(DEV_DISPLAY, (void**)&display, sizeof(DisplayDevice)) != KERNEL_OK) return KERNEL_ERROR;
    if (init_bootboot_display(display) != KERNEL_OK) return KERNEL_ERROR;

    //if (add_device(DEV_KEYBOARD, &keyboard, sizeof(KeyboardDevice)) != KERNEL_OK) return KERNEL_ERROR;
    //if (init_ps2_keyboard(keyboard) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}