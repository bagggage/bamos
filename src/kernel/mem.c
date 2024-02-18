#include "mem.h"

void* kmalloc(size_t size) {
    return NULL;
}

Status kfree(void* allocated_mem) {
    if (allocated_mem == NULL)
        return KERNEL_OK;

    return KERNEL_OK;
}