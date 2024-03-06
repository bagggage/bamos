#pragma once

#include "definitions.h"

#include <bootboot.h>

/*
Buddy page allocator.
*/

#define MAX_BLOCK_RANK 11

typedef struct BlockNode {
    uint32_t phys_page_base;
    struct BlockNode* next;


} BlockNode;

typedef struct BuddyPageAllocator {
    BlockNode block_lists[MAX_BLOCK_RANK];

    /*
    Contains state of buddies in each bit:
    0 - buddies have the same state (allocated or free);
    1 - states are different (one allocated, other free);
    */
    uint8_t bitmap;
} BuddyPageAllocator;

Status init_buddy_page_allocator(MMapEnt* boot_memory_map);

/*
Allocate virtualy linear block of requested count of 4KB pages.
Returns virtual address of the begining of the block in case of success.
In case of failure returs nullptr.
*/
void* bpa_allocate_pages(uint32_t count);

/*
Free requested count of 4KB pages that was allocated with 'bpa_allocate_pages' function before.
It's works for any count of allocated pages. But if you are frees less amount of pages that was allocated,
you must save 'new' base address of block according to deallocated pages: ((uint8_t*)base) += (count * (4 * KB_SIZE));
Also don't forget about 'new' size of block: block_size -= count; //in pages//, block_size -= count * (4 * KB_SIZE); //in bytes//.
*/
void bpa_free_pages(void* virt_base, uint32_t count);