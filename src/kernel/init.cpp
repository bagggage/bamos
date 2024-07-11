#include "definitions.h"

#include "arch.h"
#include "boot.h"
#include "logger.h"

#include "intr/intr.h"

#include "utils/list.h"

#include "video/text-output.h"

#include "vm/vm.h"

extern "C"
Status init() {
    Arch::preinit();
    TextOutput::init();

    Intr::preinit();

    info("Kernel startup on CPU: ", Arch::get_cpu_idx());
    info("CPUs detected: ", Boot::get_cpus_num());

    if (VM::init() != KERNEL_OK) return KERNEL_ERROR;

    //Intr::init();

    return KERNEL_OK;
}