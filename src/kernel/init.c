#include "init.h"

#include "dev/display.h"
#include "dev/keyboard.h"

Status init_kernel() {
    Status status = init_io_devices();

    if (status != KERNEL_OK)
        return status;

    status |= init_io_streams();

    return status;
}

Status init_io_devices() {
    // TODO

    return KERNEL_OK;
}

Status init_io_streams() {
    // TODO

    return KERNEL_OK;
}