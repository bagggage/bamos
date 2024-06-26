#pragma once

#include "cpu/spinlock.h"

#include "definitions.h"

#include "vm.h"
#include "utils/list.h"

/*
Buddy page allocator.
*/

#define BPA_MAX_BLOCK_RANK 11

typedef struct FreeArea {
    ListHead free_list;

    /*
    Contains state of buddies in each bit:
    0 - buddies have the same state (allocated or free);
    1 - states are different (one allocated, other free);
    */
    uint8_t* bitmap;
} FreeArea;

typedef struct BuddyPageAllocator {
    FreeArea free_area[BPA_MAX_BLOCK_RANK];
    Spinlock lock;

    uint32_t allocated_pages;
} BuddyPageAllocator;

Status init_buddy_page_allocator(VMMemoryMap* memory_map);

/*
Allocate virtualy linear block of requested number of 4KB pages.
BPA can allocate a number of pages equal to a power of two, the rank argument is just a power.
Returns physical address of the begining of the block in case of success.
In case of failure returns 'INVALID_ADDRESS' constant.
*/
uint64_t bpa_allocate_pages(const uint32_t rank);

/*
Free pages that was allocated with 'bpa_allocate_pages' function before.
It's works properly only with same rank argument that was used to allocate pages.
Otherwise the behavior is undefined.
*/
void bpa_free_pages(const uint64_t page_address, const uint32_t rank);

uint64_t bpa_get_allocated_bytes();

void bpa_log_free_lists(const ListHead* list);