#pragma once

#include "definitions.h"

#define PAGE_BYTE_SIZE 4096 // 4KB
#define PAGE_TABLE_MAX_SIZE 512

#define INVALID_ADDRESS 0xF000000000000000 // Invalid virtual address constant

#define MAX_PHYS_ADDRESS 0x0FFFFFFFFFF // 1TB
#define MAX_PAGE_ADDRESS 0x0FFFFFFF000
#define MAX_PAGE_BASE 0x0FFFFFFF

typedef struct PageXEntry {
    uint64_t present            : 1;
    uint64_t writeable          : 1;
    uint64_t user_access        : 1;
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1;
    uint64_t ignored_2          : 4;
    uint64_t page_ppn           : 28;
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;
} ATTR_PACKED PageXEntry;

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

typedef PageXEntry PageMapLevel4Entry;
typedef PageXEntry PageDirPtrEntry;
typedef PageXEntry PageDirEntry;

typedef struct VirtualAddress {
    uint64_t offset        : 12;
    uint64_t p1_index      : 9;
    uint64_t p2_index      : 9;
    uint64_t p3_index      : 9;
    uint64_t p4_index      : 9;
    uint64_t sign_extended : 16; // All this bites must be euals to last major bit of 'p4_index' (0xFFFF or 0x0000)
} ATTR_PACKED VirtualAddress;

static inline PageMapLevel4Entry* cpu_get_current_pml4() {
    uint64_t ptr = 0;

    asm volatile("mov %%cr3,%0":"=a"(ptr));

    return (PageMapLevel4Entry*)ptr;
}

static inline void cpu_set_pml4(PageMapLevel4Entry* pml4) {
    asm volatile("mov %0,%%cr3"::"a"(pml4));
}