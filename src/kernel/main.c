#include "init.h"
#include "logger.h"

#include "proc/task_scheduler.h"

// Entry point called from bootloader
void _start() {
    Status status = init_kernel();

    if (status == KERNEL_PANIC) {
        draw_kpanic_screen();
        _kernel_break();
    }
    else if (status != KERNEL_OK) {
        kernel_error("Initialization failed: (%e) %s\n", status, error_str);
        _kernel_break();
    }

    kernel_warn("Kernel initialized successfuly\n");

    if (load_init_proc() == FALSE) {
        kernel_error("Can't load 'init' process: %s\n", error_str);
        _kernel_break();
    }

    kernel_logger_set_color(COLOR_LGRAY);

    tsk_start_scheduler();
}