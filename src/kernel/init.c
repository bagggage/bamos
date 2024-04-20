#include "init.h"

#include <bootboot.h>
#include <stddef.h>

#include "assert.h"

#include "cpu/feature.h"

#include "dev/acpi_timer.h"
#include "dev/bootboot_display.h"
#include "dev/hpet_timer.h"
#include "dev/keyboard.h"
#include "dev/lapic_timer.h"
#include "dev/ps2_keyboard.h"
#include "dev/stds/acpi.h"
#include "dev/stds/pci.h"
#include "dev/storage.h"

#include "logger.h"
#include "mem.h"

#include "intr/apic.h"
#include "intr/intr.h"
#include "intr/ioapic.h"

#include "rawtsk/task.h"

#include "vm/vm.h"

extern BOOTBOOT bootboot;
extern const uint8_t _binary_font_psf_start;

static Spinlock cpus_init_lock = { 1 };

static void wait_for_cpu_init() {
    spin_lock(&cpus_init_lock);

    vm_setup_paging(vm_get_kernel_pml4());
    cpu_set_idtr(intr_get_kernel_idtr());

    spin_release(&cpus_init_lock);

    while (TRUE) {
        tsk_exec();
    }

    kassert(FALSE);
}

static Status split_logical_cores() {
    const uint32_t cpu_idx = cpu_get_idx();

    if (cpu_idx != 0) wait_for_cpu_init();
    if (init_kernel_logger_raw(&_binary_font_psf_start) != KERNEL_OK) return KERNEL_PANIC;

    kernel_msg("Kernel startup on CPU %u\n", cpu_idx);
    kernel_msg("CPUs detected: %u\n", bootboot.numcores);

    return KERNEL_OK;
}

extern uint32_t fb[];

static Status init_timer() {
    if (is_acpi_timer_avail() == FALSE) {
        error_str = "There is no supported timer device";
        return KERNEL_ERROR;
    }

    TimerDevice* acpi_timer = (TimerDevice*)dev_push(DEV_TIMER, sizeof(TimerDevice));
    TimerDevice* lapic_timer = (TimerDevice*)dev_push(DEV_TIMER, sizeof(TimerDevice));

    if (acpi_timer == NULL || lapic_timer == NULL) return KERNEL_ERROR;

    if (init_acpi_timer(acpi_timer) != KERNEL_OK) return KERNEL_ERROR;
    if (init_lapic_timer(lapic_timer) != KERNEL_OK) return KERNEL_ERROR;

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

Status init_pci() {
    PciDevice* pci_device = (PciDevice*)dev_push(DEV_PCI_BUS, sizeof(PciDevice));

    if (pci_device == NULL) return KERNEL_ERROR;

    if (init_pci_device(pci_device) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_storage() {
    StorageDevice* storage_device = (StorageDevice*)dev_push(DEV_STORAGE, sizeof(StorageDevice));

    if (storage_device == NULL) return KERNEL_ERROR;

    if (init_storage_device(storage_device) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_kernel() {
    if (split_logical_cores() != KERNEL_OK) return KERNEL_PANIC;

    if (init_intr()         != KERNEL_OK) return KERNEL_PANIC;
    if (init_memory()       != KERNEL_OK) return KERNEL_ERROR;

    spin_release(&cpus_init_lock);

    if (init_acpi()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_apic()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_ioapic()       != KERNEL_OK) return KERNEL_ERROR;
    if (init_io_devices()   != KERNEL_OK) return KERNEL_ERROR;
    if (init_timer()        != KERNEL_OK) return KERNEL_ERROR;
    if (init_pci()          != KERNEL_OK) return KERNEL_ERROR;
    if (init_storage()      != KERNEL_OK) return KERNEL_ERROR;
    
    return KERNEL_OK;
}

Status init_io_devices() {
    // TODO
    DisplayDevice* display = (DisplayDevice*)dev_push(DEV_DISPLAY, sizeof(DisplayDevice));
    KeyboardDevice* keyboard = (KeyboardDevice*)dev_push(DEV_KEYBOARD, sizeof(KeyboardDevice));

    if (display == NULL || keyboard == NULL) return KERNEL_ERROR;

    if (init_bootboot_display(display) != KERNEL_OK) return KERNEL_ERROR;
    //if (init_ps2_keyboard(keyboard) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}