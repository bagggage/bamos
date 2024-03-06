#pragma once

#include "definitions.h"

Status init_memory();

// Kernel space memory allocation
void* kmalloc(size_t size);
// Kernel space memory free
void kfree(void* allocated_mem);

/*
Map physical memory pages to virtual.
Never fails, so be carefull when using this function and always check if virtual addresses already taken
or physcical memory was allocated before for other purposes.
*/
void map_phys_to_virt(uint64_t physcical_addr, uint64_t virtual_addr, uint64_t pages_count);

// Allocate pages in common heap
void* alloc_pages(size_t count);
// Free previously alloceted pages in common heap
void free_pages(void* begin, size_t count);

// Check if virtual address is mapped (but also can be not presented)
bool_t is_virt_addr_mapped(uint64_t address);

/*
Returns physical address that mapped to virtual.
If virtual address is not mapped returns 'INVALID_ADDRESS'.
*/
uint64_t get_phys_address(uint64_t virt_addres);

void memcpy(const void* src, void* dst, size_t size);
void memset(void* dst, size_t size, uint8_t value);