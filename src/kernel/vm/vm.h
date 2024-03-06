#pragma once

#include "definitions.h"

#include <bootboot.h>

/*
Virtual memory.
*/

#define KERNEL_STACK_SIZE (2 * MB_SIZE)

typedef struct RawMemoryBlock {
    uint64_t phys_address;
    uint64_t virt_address;
    size_t size;
} RawMemoryBlock;

typedef enum VMMapFlags{
    VMMAP_DEFAULT = 0x0,            // Use default flags: no large pages, collision checks enabled
    VMMAP_FORCE = 0x1,              // Force to map, does't check collisions.
    VMMAP_USE_LARGE_PAGES = 0x2,    // Uses large pages (2MB or 1GB) for long regions
} VMMapFlags;

extern RawMemoryBlock vm_kernel_stack;
extern RawMemoryBlock vm_kernel_segments;

Status init_virtual_memory(const MMapEnt* bootboot_mem_map, const size_t entries_count);

/*
Map physical pages to virtual in required count.
Physicall and virtual address must be page aligned, if not - undefined behaviour.
Returns 'KERNEL_OK' in case of success. Otherwise returns 'KERNEL_ERROR' and does't apply any changes.
*/
Status vm_map_phys_to_virt(const uint64_t phys_addr, const uint64_t virt_addr, const size_t pages_count, VMMapFlags flags);