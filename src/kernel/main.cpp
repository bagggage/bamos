#include "definitions.h"

extern "C" Status init();

extern "C"
[[noreturn]] void _start() {
    init();

    _kernel_break();
    //if (init() != KERNEL_OK) panic("Failed to initialize kernel:", error_str);

    //Task* const task = Process::load(INIT_PROG_PATH);
//
    //if (task == NULL) {
    //    logger.error("Loading `init` program failed:", error_str);
    //    _kernel_break();
    //}
//
    //Scheduler::push_task(task);
    //Scheduler::schedule();
    //Scheduler::handle();
}