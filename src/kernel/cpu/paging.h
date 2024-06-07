#pragma once

#include "definitions.h"

#define PAGE_BYTE_SIZE 4096U // 4KB
#define PAGE_TABLE_MAX_SIZE 512U

#define PAGES_PER_2MB ((2U * MB_SIZE) / PAGE_BYTE_SIZE)

#define INVALID_ADDRESS 0xF000000000000000 // Invalid virtual address constant

#define MAX_PHYS_ADDRESS 0x0FFFFFFFFFF // 1TB
#define MAX_PAGE_ADDRESS 0x0FFFFFFF000
#define MAX_PAGE_BASE 0x0FFFFFFF

typedef struct PageXEntry {
    uint64_t present            : 1; // If set, means next level page entry can be accessed
    uint64_t writeable          : 1; // If set, read/write allowed, otherwise read-only
    uint64_t user_access        : 1; // If set, allow user access
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1; // If set, for P3 size == 1GB; P2 size == 2MB
    uint64_t global             : 1;
    uint64_t ignored_2          : 3;
    uint64_t page_ppn           : 28; // Page table base physical address
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;  // If set, then execution disabled
} ATTR_PACKED PageXEntry;

typedef struct PageTableEntry {
    uint64_t present            : 1;  // If set, means next level page entry can be accessed
    uint64_t writeable          : 1;  // If set, read/write allowed, otherwise read-only
    uint64_t user_access        : 1;  // If set, allow user access
    uint64_t write_through      : 1;
    uint64_t cache_disabled     : 1;
    uint64_t accessed           : 1;
    uint64_t dirty              : 1;
    uint64_t size               : 1;  // Must be 0
    uint64_t global             : 1;  //
    uint64_t ignored_2          : 3;
    uint64_t page_ppn           : 28; // Page base physical address
    uint64_t reserved_1         : 12; // Must be 0
    uint64_t ignored_1          : 11;
    uint64_t execution_disabled : 1;  // If set, then execution disabled
} ATTR_PACKED PageTableEntry;

typedef PageXEntry PageMapLevel4Entry;
typedef PageXEntry PageDirPtrEntry;
typedef PageXEntry PageDirEntry;

typedef union VirtualAddress {
    struct {
        uint64_t offset        : 12;
        uint64_t p1_index      : 9;
        uint64_t p2_index      : 9;
        uint64_t p3_index      : 9;
        uint64_t p4_index      : 9;
        uint64_t sign_extended : 16; // All this bites must be euals to last major bit of 'p4_index' (0xFFFF or 0x0000)
    };
    uint64_t value;
} ATTR_PACKED VirtualAddress;

typedef struct CR3 {
    uint64_t ignored_0  : 3;
    uint64_t pwt        : 1;
    uint64_t pcd        : 1;
    uint64_t ignored_1  : 7;
    uint64_t pml4_base  : 52; 
} ATTR_PACKED CR3; 

static inline bool_t is_virt_address_valid(const uint64_t address) {
    const VirtualAddress* virtual_addr = (const VirtualAddress*)&address;

    return (virtual_addr->sign_extended == 0 || virtual_addr->sign_extended == 0xFFFF);
}

static inline PageMapLevel4Entry* cpu_get_current_pml4() {
    CR3 cr3;

    asm volatile("mov %%cr3,%0":"=a"(cr3));

    return (PageMapLevel4Entry*)((uint64_t)cr3.pml4_base << 12);
}

static inline void cpu_set_pml4(PageMapLevel4Entry* pml4_phys_addr) {
    CR3 cr3;

    asm volatile("mov %%cr3,%0":"=a"(cr3));

    cr3.pml4_base = ((uint64_t)pml4_phys_addr >> 12);

    asm volatile("mov %0,%%cr3"::"a"(cr3));
}