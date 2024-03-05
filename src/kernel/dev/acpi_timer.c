#include "acpi_timer.h"

#include "logger.h"

#include "cpu/io.h"

#include "dev/stds/acpi.h"

#include "intr/intr.h"

#define ACPI_PMT_RATE 3579545 // 3.57 Mhz
#define ACPI_PMT_MIN_CLOCK_TIME_IN_IN_PS ((uint64_t)279000)

bool_t is_extended_mode = FALSE;

bool_t is_acpi_timer_avail() {
    return acpi_fadt->pm_timer_length == 4;
}

static uint64_t get_acpi_mmio_clock_counter(TimerDevice*) {
    // TODO
    return 0;
}

static uint64_t get_acpi_io_clock_counter(TimerDevice*) {
    uint32_t counter;

    counter = inl(acpi_fadt->pm_timer_block);

    return (uint64_t)counter;
}

Status init_acpi_timer(TimerDevice* dev) {
    if (dev == NULL) return KERNEL_INVALID_ARGS;
    
    if (is_acpi_timer_avail() == FALSE) {
        error_str = "ACPI Timer not available";
        return KERNEL_ERROR;
    }

    dev->common.type = DEV_TIMER;

    if (acpi_fadt->flags & (1 << 8)) {
        is_extended_mode = TRUE;

        if (is_acpi_reserved_address_space(&acpi_fadt->x_pm_timer_block)) {
            dev->interface.get_clock_counter = &get_acpi_io_clock_counter;
        }
        else {
            dev->interface.get_clock_counter = (acpi_fadt->x_pm_timer_block.address_space_id == ADDRESS_SPACE_SYSTEM_IO) ?
                &get_acpi_io_clock_counter : &get_acpi_mmio_clock_counter;
        }
    }
    else {
        dev->interface.get_clock_counter = &get_acpi_io_clock_counter;
    }

    dev->min_clock_time = ACPI_PMT_MIN_CLOCK_TIME_IN_IN_PS;

    return KERNEL_OK;
}