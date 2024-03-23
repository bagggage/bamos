#pragma once

#include "definitions.h"

#include <bootboot.h>

#include "cpu/paging.h"

/*
Virtual memory.
*/

#define KERNEL_STACK_SIZE (KB_SIZE * 4)

#define PAGE_TABLE_POOL_TABLES_COUNT 512
#define PAGE_TABLE_SIZE PAGE_BYTE_SIZE

typedef struct RawMemoryBlock {
    uint64_t phys_address;
    uint64_t virt_address;
    size_t size;
} RawMemoryBlock;

typedef enum VMMapFlags{
    VMMAP_DEFAULT = 0x0,            // Use default flags: no large pages, collision checks enabled, read-only, no user access.
    VMMAP_FORCE = 0x1,              // Force to map, does't check collisions.
    VMMAP_USE_LARGE_PAGES = 0x2,    // Uses large pages (2MB or 1GB) for long regions.
    VMMAP_WRITE = 0x4,              // Allow to write to memory.
    VMMAP_EXEC = 0x8,               // Allow execute instructions from this memory.
    VMMAP_USER_ACCESS = 0x10        // Allow user access.
} VMMapFlags;

#define VMMAP_PRIOR_FLAGS (VMMAP_EXEC | VMMAP_WRITE | VMMAP_USER_ACCESS)

extern PageMapLevel4Entry vm_pml4[PAGE_TABLE_MAX_SIZE];

extern RawMemoryBlock vm_kernel_stack;
extern RawMemoryBlock vm_kernel_segments;

extern uint64_t vm_kernel_virt_to_phys_offset;

// Conver any kernel space address from virtual to physical
static inline uint64_t vm_kernel_virt_to_phys(const uint64_t kernel_virt_address) {
    return kernel_virt_address + vm_kernel_virt_to_phys_offset;
}

// Round value to upper bound
static inline uint64_t div_with_roundup(const uint64_t value, const uint64_t divider) {
    return (value / divider) + ((value % divider) == 0 ? 0 : 1);
}

Status init_virtual_memory(MMapEnt* bootboot_mem_map, const size_t entries_count);

/*
Map physical pages to virtual in required count.
Physicall and virtual address must be page aligned, if not - undefined behaviour.
Returns 'KERNEL_OK' in case of success. Otherwise returns 'KERNEL_ERROR' and does't apply any changes.
*/
Status vm_map_phys_to_virt(uint64_t phys_address, uint64_t virt_address, const size_t pages_count, VMMapFlags flags);

/*
Allocate page table from the static page tables pool and clear all entries.
The size of the pool is defined as 'PAGE_TABLE_POOL_TABLES_COUNT'.
Returns virtual address in case of success. Otherwise returns nullptr.
*/
PageXEntry* vm_alloc_page_table();
PageXEntry* vm_get_page_x_entry(const uint64_t virt_address, unsigned int level);