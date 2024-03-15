#include "init.h"
#include "logger.h"

#include "dev/stds/pci.h"

// Entry point called from bootloader
void _start() {
    Status status = init_kernel();

    if (status == KERNEL_ERROR) {
        kernel_error("Initialization failed: (%e) %s\n", status, error_str);
        _kernel_break();
    }
    else if (status == KERNEL_PANIC) {
        draw_kpanic_screen();
        _kernel_break();
    }

    kernel_msg("Kernel initialized successfuly\n");

    log_pci_devices();

    _kernel_break();
}