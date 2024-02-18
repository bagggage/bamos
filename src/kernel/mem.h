#pragma once

#include "definitions.h"

// Kernel space memory allocation
void* ker_alloc(size_t size);
// Kernel space memory free
Status ker_free(void* allocated_mem);