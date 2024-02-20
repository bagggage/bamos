#pragma once

#include "definitions.h"

#define KB_SIZE 1024
#define MB_SIZE (KB_SIZE * 1024)
#define GB_SIZE (MB_SIZE * 1024)

#define PAGE_BYTE_SIZE 4096 // 4KB
#define PAGE_KB_SIZE (PAGE_BYTE_SIZE / KB_SIZE)

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