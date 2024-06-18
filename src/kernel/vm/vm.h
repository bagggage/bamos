#pragma once

#include "definitions.h"
#include "heap.h"

#include "cpu/paging.h"

#include "utils/list.h"

#include <bootboot.h>

/*
Virtual memory.
*/

#define DMA_VIRT_ADDRESS 0x0
#define DMA_SIZE (GB_SIZE * 512ULL)
#define KERNEL_HEAP_VIRT_ADDRESS 0xFFFFFE0000000000
#define KERNEL_STACK_SIZE (KB_SIZE * 4)

#define USER_SPACE_ADDR_BEGIN (DMA_VIRT_ADDRESS + DMA_SIZE)

#define PAGE_TABLE_SIZE PAGE_BYTE_SIZE

typedef struct MemoryBlock {
    uint64_t address;
    uint32_t pages_count;
} MemoryBlock;

typedef struct VMMemoryBlock {
    uint64_t virt_address;
    uint32_t page_base;
    uint32_t pages_count;
} VMMemoryBlock;

typedef struct RawMemoryBlock {
    uint64_t phys_address;
    uint64_t virt_address;
    size_t size;
} RawMemoryBlock;

typedef struct KernelAddressSpace {
    RawMemoryBlock segments;
    RawMemoryBlock stack;
    RawMemoryBlock heap;
} KernelAddressSpace;

typedef enum VMMapFlags{
    VMMAP_DEFAULT = 0x0,            // Use default flags: no large pages, collision checks enabled, read-only, no user access.
    VMMAP_FORCE = 0x1,              // Force to map, does't check collisions.
    VMMAP_USE_LARGE_PAGES = 0x2,    // Uses large pages (2MB or 1GB) for long regions.
    VMMAP_WRITE = 0x4,              // Allow to write to memory.
    VMMAP_EXEC = 0x8,               // Allow execute instructions from this memory.
    VMMAP_USER_ACCESS = 0x10,       // Allow user access.
    VMMAP_WRITE_THROW = 0x20,       // Write to cache and memory at the same time.
    VMMAP_CACHE_DISABLED = 0x40,    // Disable writing to cache.
    VMMAP_GLOBAL = 0x80             // Save translation cache after switching page tables.
} VMMapFlags;

typedef struct VMPageList {
    LIST_STRUCT_IMPL(VMPageList);

    uint32_t phys_page_base;
} VMPageList;

/*
Virtual memory page frame descriptor.
*/
typedef struct VMPageFrame {
    uint32_t count;
    uint64_t virt_address;
    ListHead phys_pages;
    VMMapFlags flags;
} VMPageFrame;

typedef struct VMMemoryMapEntry {
    uint32_t compact_phys_address;
    uint32_t pages_count;

    enum VMMemmoryMapEntryType {
        VMMEM_TYPE_FREE,    // free to use
        VMMEM_TYPE_USED,    // used for unknown perposes
        VMMEM_TYPE_DEV,     // reserved for devices
        VMMEM_TYPE_KERNEL,  // kernel code/data/stack segments
        VMMEM_TYPE_ALLOC    // pre-allocated by direct searching of free memory block
    } type;
} VMMemoryMapEntry;

/*
Structure that returned after virtual memory initialization.
Map contains information about all physical ram.
Entries array stored in a random free memory region, and don't need to be freed.
This map actually used only for page allocator initialization and can't
be accessed after it.
*/
typedef struct VMMemoryMap {
    VMMemoryMapEntry* entries;
    uint32_t count;

    // Total count of pages that can be used by OS
    uint32_t total_pages_count;
} VMMemoryMap;

void log_memory_map(const VMMemoryMap* memory_map);

PageMapLevel4Entry* vm_get_kernel_pml4();
VMHeap* vm_get_kernel_heap();

Status init_virtual_memory(MMapEnt* boot_memory_map, const size_t entries_count, VMMemoryMap* out_memory_map);
Status init_vm_allocator();

/*
Map physical pages to virtual in required count.
Physicall and virtual address must be page aligned, if not - undefined behaviour.
Returns 'KERNEL_OK' in case of success. Otherwise returns 'KERNEL_ERROR' and does't apply any changes.
*/
Status _vm_map_phys_to_virt(
    uint64_t phys_address, uint64_t virt_address,
    PageMapLevel4Entry* pml4, const size_t pages_count,
    VMMapFlags flags
);
Status vm_map_phys_to_virt(uint64_t phys_address, uint64_t virt_address, const size_t pages_count, VMMapFlags flags);

uint64_t vm_map_mmio(const uint64_t phys_address, const uint32_t pages_count);

void vm_unmap(const uint64_t virt_address, PageMapLevel4Entry* pml4, const uint32_t pages_count);

/*
Allocate page table from the static page tables pool and clear all entries.
The size of the pool is defined as 'PAGE_TABLE_POOL_TABLES_COUNT'.
Returns virtual address in case of success. Otherwise returns nullptr.
*/
PageXEntry* vm_alloc_page_table();
void vm_free_page_table(PageXEntry* page_table);

PageXEntry* vm_get_page_x_entry(const uint64_t virt_address, unsigned int level);
PageXEntry* _get_page_x_entry(PageMapLevel4Entry* pml4, const uint64_t virt_address, unsigned int level);

/*
Allocate physical pages at the init stage when BPA is not available
*/
VMMemoryMapEntry* _vm_boot_alloc(VMMemoryMap* memory_map, const uint32_t pages_count);

/*
Walks through page tables and looks for a linear range of virtual addresses.
Returns the start of linear addresses range. If requested range was not found returns 'INVALID_ADDRESS'.
*/
uint64_t vm_find_free_virt_address(const PageMapLevel4Entry* pml4, const uint32_t pages_count);

/*
Allocates linear block of virtual pages with requested options. 
*/
VMPageFrame vm_alloc_pages(const uint32_t pages_count, VMHeap* heap, PageMapLevel4Entry* pml4, VMMapFlags flags);
VMPageFrame _vm_alloc_pages(const uint32_t pages_count, const uint64_t virt_address, PageMapLevel4Entry* pml4, VMMapFlags flags);

/*
Frees virtual pages previously allocated with 'vm_alloc_pages'.
*/
void vm_free_pages(VMPageFrame* page_frame, VMHeap* heap, PageMapLevel4Entry* pml4);

bool_t vm_test();

void vm_setup_paging(PageMapLevel4Entry* pml4);
void vm_map_kernel(PageMapLevel4Entry* pml4);
void vm_configure_cpu_page_table();
void _vm_map_proc_local(PageMapLevel4Entry* pml4);

static inline bool_t vm_is_mem_contains(const VMMemoryBlock* block, const uint64_t virt_address) {
    return (
        virt_address >= block->virt_address &&
        virt_address < block->virt_address +
        ((uint64_t)block->pages_count * PAGE_BYTE_SIZE)
    );
}