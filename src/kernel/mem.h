#pragma once

#include "definitions.h"

#define KB_SIZE 1024
#define MB_SIZE (KB_SIZE * 1024)
#define GB_SIZE (MB_SIZE * 1024)

#define PAGE_BYTE_SIZE 4096 // 4KB
#define PAGE_KB_SIZE (PAGE_BYTE_SIZE / KB_SIZE)

#define PAGE_TABLE_MAX_SIZE 512

#define INVALID_ADDRESS 0xF000000000000000 // Invalid virtual address constant

#define MAX_PHYS_ADDRESS 0x0FFFFFFFFFF // 1TB
#define MAX_PAGE_ADDRESS 0x0FFFFFFF000
#define MAX_PAGE_BASE 0x0FFFFFFF

typedef struct PageMapLevel4Entry {
    uint64_t present            : 1;
    uint64_t writeable          : 1;
    uint64_t user_access        : 1;
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1; // Must be 0
    uint64_t ignored_2          : 4;
    uint64_t page_ppn           : 28;
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;
} ATTR_PACKED PageMapLevel4Entry;

typedef struct PageDirPtrEntry {
    uint64_t present            : 1;
    uint64_t writeable          : 1;
    uint64_t user_access        : 1;
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1; // 0 means page directory mapped
    uint64_t ignored_2          : 4;
    uint64_t page_ppn           : 28;
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;
} ATTR_PACKED PageDirPtrEntry;

typedef struct PageDirEntry {
    uint64_t present            : 1;
    uint64_t writeable          : 1;
    uint64_t user_access        : 1;
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1; // 0 means page table mapped
    uint64_t ignored_2          : 4;
    uint64_t page_ppn           : 28;
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;
} ATTR_PACKED PageDirEntry;

typedef struct PageTableEntry {
    uint64_t present            : 1;
    uint64_t writeable          : 1;
    uint64_t user_access        : 1;
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1;
    uint64_t global             : 1;
    uint64_t ignored_2          : 3;
    uint64_t page_ppn           : 28;
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;
} ATTR_PACKED PageTableEntry;

typedef struct VirtualAddress {
    uint64_t offset        : 12;
    uint64_t p1_index      : 9;
    uint64_t p2_index      : 9;
    uint64_t p3_index      : 9;
    uint64_t p4_index      : 9;
    uint64_t sign_extended : 16; // All this bites must be euals to last major bit of 'p4_index' (0xFFFF or 0x0000)
} ATTR_PACKED VirtualAddress;

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