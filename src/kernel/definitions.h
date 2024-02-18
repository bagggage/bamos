#pragma once

// Kernel defenitions used in implementetion

// Result of the operation
typedef enum Status {
    KERNEL_OK = 0,
    KERNEL_COUGHT,
    KERNEL_ERROR,
    KERNEL_PANIC,
} Status;