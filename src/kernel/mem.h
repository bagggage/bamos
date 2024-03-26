#pragma once

#include "definitions.h"

#include <bootboot.h>

#include "cpu/paging.h"

/*
Kernel high-level memory interface.
This file provide high-level memory functions for kernel-space.
*/

Status init_memory();

// Kernel space memory allocation
void* kmalloc(size_t size);
// Kernel space memory free
void kfree(void* allocated_mem);

void log_memory_page_tables(PageMapLevel4Entry* pml4);
void log_boot_memory_map(const MMapEnt* memory_map, const size_t entries_count);

// Allocate pages in common heap
void* alloc_pages(size_t count);
// Free previously alloceted pages in common heap
void free_pages(void* begin, size_t count);

// Check if virtual address is mapped (but also can be not presented)
bool_t is_virt_addr_mapped(const uint64_t address);

/*
Returns physical address that mapped to virtual.
If virtual address is not mapped returns 'INVALID_ADDRESS'.
*/
uint64_t get_phys_address(const uint64_t virt_addres);

void memcpy(const void* src, void* dst, size_t size);
void memset(void* dst, size_t size, uint8_t value);

// Page X table entry
typedef struct VMPxE {
    uint64_t entry : 62;    // Physical base of the entry
    uint64_t level : 2;     // Page table level from PML4(0) to PT(3)
} ATTR_PACKED VMPxE;

VMPxE get_pxe_of_virt_addr(const uint64_t address);