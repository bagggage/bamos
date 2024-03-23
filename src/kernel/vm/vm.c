#include "vm.h"

#include <bootboot.h>

#include "assert.h"

#include "cpu/regs.h"

#include "logger.h"
#include "mem.h"

extern BOOTBOOT bootboot;

extern uint64_t kernel_elf_start;
extern uint64_t kernel_elf_end;

RawMemoryBlock vm_kernel_stack;
RawMemoryBlock vm_kernel_segments = { 0, &kernel_elf_start, 0 };

// PML4
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageMapLevel4Entry vm_pml4[PAGE_TABLE_MAX_SIZE];

// PDPT
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageDirPtrEntry vm_low_pdpt[PAGE_TABLE_MAX_SIZE];
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageDirPtrEntry vm_high_pdpt[PAGE_TABLE_MAX_SIZE];

// Pool of memory that used to allocating page tables
static PageXEntry* vm_page_table_pool = NULL;

// Count of page tables in pool
static size_t vm_page_table_pool_size = 0;
static uint8_t vm_page_table_pool_bitmap[PAGE_TABLE_POOL_TABLES_COUNT / 8];

uint64_t vm_kernel_virt_to_phys_offset = 0;

// Linker setted stack size
extern uint64_t initstack[];

static inline const MMapEnt* find_free_mem_map_entry(MMapEnt* mem_map, const size_t entries_count, const size_t required_size) {
    const MMapEnt* most_suitable_entry = NULL;

    for (size_t i = 0; i < entries_count; ++i) {
        const MMapEnt* entry = mem_map + i;

        if (MMapEnt_Type(entry) == MMAP_FREE &&
            MMapEnt_Size(entry) >= required_size &&
            (most_suitable_entry == NULL ||
            MMapEnt_Size(most_suitable_entry) > MMapEnt_Size(entry))) {
            most_suitable_entry = entry;
        }
    }

    return most_suitable_entry;
}

static const MMapEnt find_first_suitable_mmap_block(MMapEnt* begin_entry, const size_t entries_count, const size_t pages_count) {
    for (size_t i = 0; i < entries_count - (((uint64_t)begin_entry - (uint64_t)&bootboot.mmap.ptr) / sizeof(MMapEnt)); ++i) {
        MMapEnt* entry = begin_entry + i;

        if (MMapEnt_Type(entry) != MMAP_FREE || MMapEnt_Size(entry) < pages_count * PAGE_BYTE_SIZE) continue;

        MMapEnt result = *entry;
        result.size = pages_count * PAGE_BYTE_SIZE;

        entry->ptr = entry->ptr + result.size;
        entry->size = (MMapEnt_Size(entry) - result.size) | MMAP_FREE;

        return result;
    }

    return (MMapEnt){ 0, 0 };
}

static inline bool_t is_virt_addr_valid(const uint64_t virt_address) {
    VirtualAddress* virtual_addr = (VirtualAddress*)&virt_address;

    return (virtual_addr->sign_extended == 0 || virtual_addr->sign_extended == 0xFFFF);
}

static inline bool_t is_page_table_entry_valid(const PageXEntry* pte) {
    return *(uint64_t*)pte != 0;
}

// Clear all entries
static void vm_init_page_table(PageXEntry* page_table) {
    kassert(page_table != NULL);

    for (uint32_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        *(uint64_t*)(page_table + i) = 0;
    }
}

static void vm_config_page_table_entry(PageXEntry* page_table_entry, const uint64_t redirection_base, VMMapFlags flags) {
    page_table_entry->present               = 1;
    page_table_entry->writeable             = ((flags & VMMAP_WRITE) != 0);
    page_table_entry->execution_disabled    = ((flags & VMMAP_EXEC) == 0);
    page_table_entry->user_access           = ((flags & VMMAP_USER_ACCESS) != 0);
    page_table_entry->size                  = ((flags & VMMAP_USE_LARGE_PAGES) != 0);
    page_table_entry->page_ppn              = (redirection_base >> 12);
}

static void vm_init_page_tables() {
    // Init with zeroes
    vm_init_page_table(&vm_pml4);
    vm_init_page_table(&vm_low_pdpt);
    vm_init_page_table(&vm_high_pdpt);

    // Low half
    vm_config_page_table_entry(&vm_pml4[0],
                            vm_kernel_virt_to_phys((uint64_t)&vm_low_pdpt),
                            VMMAP_USER_ACCESS | VMMAP_EXEC | VMMAP_WRITE);

    // High half
    vm_config_page_table_entry(&vm_pml4[PAGE_TABLE_MAX_SIZE - 1],
                            vm_kernel_virt_to_phys((uint64_t)&vm_high_pdpt),
                            VMMAP_EXEC | VMMAP_WRITE);
}

Status init_virtual_memory(MMapEnt* bootboot_mem_map, const size_t entries_count) {
    kassert(bootboot_mem_map != NULL && entries_count > 0);

    vm_kernel_virt_to_phys_offset = get_phys_address(vm_kernel_segments.virt_address) - vm_kernel_segments.virt_address;

    vm_kernel_segments.phys_address = vm_kernel_virt_to_phys(vm_kernel_segments.virt_address);
    vm_kernel_segments.size = (uint64_t)&kernel_elf_end - (uint64_t)&kernel_elf_start;

    kernel_msg("Kernel: %x\n", get_phys_address((uint64_t)&kernel_elf_start));
    kernel_msg("Kernel size: %u KB (%u MB)\n", vm_kernel_segments.size / KB_SIZE, vm_kernel_segments.size / MB_SIZE);
    kernel_msg("Framebuffer: %x\n", get_phys_address((uint64_t)BOOTBOOT_FB));
    kernel_msg("Kernel virtual address space offset: %x\n", vm_kernel_virt_to_phys_offset);

    // Init pages pool
    const MMapEnt pages_pool_mmap_entry =
        find_first_suitable_mmap_block(bootboot_mem_map, entries_count, PAGE_TABLE_POOL_TABLES_COUNT);
    //

    if (pages_pool_mmap_entry.size == 0) {
        error_str = "Not found suitable memory block for paging tables pool";
        return KERNEL_ERROR;
    }

    vm_page_table_pool = (PageXEntry*)pages_pool_mmap_entry.ptr;
    vm_page_table_pool_size = PAGE_TABLE_POOL_TABLES_COUNT;

    vm_init_page_tables();

    // Replace and map stack
    const MMapEnt stack_mmap_entry =
        find_first_suitable_mmap_block(bootboot_mem_map, entries_count, KERNEL_STACK_SIZE / PAGE_BYTE_SIZE);

    if (stack_mmap_entry.size == 0) {
        error_str = "Not found suitable memory block for replacing stack";
        return KERNEL_ERROR;
    }

    vm_kernel_stack.phys_address = stack_mmap_entry.ptr;
    vm_kernel_stack.virt_address = (UINT64_MAX - KERNEL_STACK_SIZE) + 1;
    vm_kernel_stack.size = KERNEL_STACK_SIZE;

    const void* stack_src_virt_ptr = (void*)((UINT64_MAX - (uint64_t)initstack) + 1);

    //Map 2GB physical identity
    vm_map_phys_to_virt(0x0,
                        0x0,
                        div_with_roundup(8 * GB_SIZE, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));
    //

    // Map framebuffer
    vm_map_phys_to_virt(bootboot.fb_ptr,
                        BOOTBOOT_FB,
                        div_with_roundup(bootboot.fb_size, (2 * MB_SIZE)) * PAGES_PER_2MB,
                        (VMMAP_FORCE | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));
    //

    // Map bootboot
    vm_map_phys_to_virt(get_phys_address((uint64_t)&bootboot),
                        (uint64_t)&bootboot,
                        div_with_roundup(bootboot.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_WRITE));

    // Map kernel
    vm_map_phys_to_virt(vm_kernel_segments.phys_address,
                        vm_kernel_segments.virt_address,
                        div_with_roundup(vm_kernel_segments.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE));
    //

    // Map stack
    vm_map_phys_to_virt(get_phys_address((uint64_t)stack_src_virt_ptr),
                        stack_src_virt_ptr,
                        vm_kernel_stack.size / PAGE_BYTE_SIZE,
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));
    //

    log_memory_page_tables((PageMapLevel4Entry*)vm_kernel_virt_to_phys(&vm_pml4));

    // Enable OS paging
    cpu_set_pml4((PageMapLevel4Entry*)vm_kernel_virt_to_phys((uint64_t)&vm_pml4));
    kernel_warn("OS Page tables enabled\n");

    return KERNEL_OK;
}

PageXEntry* vm_alloc_page_table() {
    for (uint16_t i = 0; i < sizeof(vm_page_table_pool_bitmap); ++i) {
        if (vm_page_table_pool_bitmap[i] == 0xFF) continue;

        uint8_t bitmask = 1;

        for (uint8_t j = 0; j < 8; ++j) {
            if (vm_page_table_pool_bitmap[i] & bitmask) {
                bitmask <<= 1;
                continue;
            }

            vm_page_table_pool_bitmap[i] |= bitmask;

            PageXEntry* page_table = &vm_page_table_pool[((i * 8) + j) * PAGE_TABLE_MAX_SIZE];

            vm_init_page_table(page_table);

            return page_table;
        }
    }

    return NULL;
}

// Takes physical address
void vm_free_page_table(PageXEntry* page_table) {
    kassert(page_table != NULL);

    const uint64_t table_idx_offset_in_pool = (((uint64_t)vm_page_table_pool - (uint64_t)page_table) / 8) / PAGE_TABLE_MAX_SIZE;
    const uint32_t bitmap_byte_idx = table_idx_offset_in_pool / 8;
    const uint8_t bitmap_bit_idx = table_idx_offset_in_pool % 8;

    vm_page_table_pool_bitmap[bitmap_byte_idx] &= (~(0x1 << bitmap_bit_idx));
}

static inline bool_t vm_is_pxe_valid(const PageXEntry* pxe) {
    return pxe->present && (pxe->size == 1 || pxe->page_ppn != 0);
}

PageXEntry* vm_get_page_x_entry(const uint64_t virt_address, unsigned int level) {
    kassert(level < 4);

    PageXEntry* pxe = (PageXEntry*)vm_kernel_virt_to_phys((uint64_t)&vm_pml4) + (uint16_t)((const VirtualAddress*)&virt_address)->p4_index;
    uint8_t offset_shift = 30;

    for (uint16_t i = 0; i < level; ++i) {
        pxe = (PageXEntry*)((uint64_t)pxe->page_ppn << 12) + ((*(uint64_t*)&virt_address >> offset_shift) & 0x1FF);
        offset_shift -= 9;
    }

    return pxe;
}

static inline void vm_allow_pxe_flags(PageXEntry* pxe, VMMapFlags flags) {
    pxe->present            = 1;
    pxe->writeable          |= ((flags & VMMAP_WRITE) == 1);
    pxe->user_access        |= ((flags & VMMAP_USER_ACCESS) == 1);
    pxe->execution_disabled &= ((flags & VMMAP_EXEC) == 0);
}

Status vm_map_phys_to_virt(uint64_t phys_address, uint64_t virt_address, const size_t pages_count, VMMapFlags flags) {
    kassert(phys_address <= MAX_PHYS_ADDRESS);
    kassert(pages_count < MAX_PAGE_BASE);

    if (is_virt_addr_valid(virt_address) == FALSE) return KERNEL_ERROR;

    static const uint64_t level_size_table[3] = { GB_SIZE, (2 * MB_SIZE), PAGE_BYTE_SIZE };

    uint32_t pages_by_size_count[4] = { 0, 0, pages_count, 0 };

    if ((flags & VMMAP_USE_LARGE_PAGES) != 0) {
        pages_by_size_count[0] = (pages_count * PAGE_BYTE_SIZE) / GB_SIZE; // 1GB
        pages_by_size_count[1] = ((pages_count * PAGE_BYTE_SIZE) / (2U * MB_SIZE)); // 2MB
        pages_by_size_count[2] -= (pages_by_size_count[1] * PAGE_TABLE_MAX_SIZE); // 4KB
        // the last pages count must always be 0, this entry exists only for checking

        pages_by_size_count[1] -= (pages_by_size_count[0] * PAGE_TABLE_MAX_SIZE);
    }

    // Debug
    //kernel_msg("1GB: %u, 2MB: %u; 4KB: %u\n", pages_by_size_count[0], pages_by_size_count[1], pages_by_size_count[2]);

    uint32_t offset_shift = 39;

    PageXEntry* pxe = (PageXEntry*)vm_kernel_virt_to_phys((uint64_t)&vm_pml4) + ((virt_address >> offset_shift) & 0x1FF);
    offset_shift -= 9;

    for (int i = 0; i < 4; ++i) {
        const bool_t is_need_to_map_on_this_level = (i != 0 && pages_by_size_count[i - 1] > 0);
        const bool_t has_pages_to_allocate = (*(uint64_t*)(pages_by_size_count + (i == 0 ? 1 : i)) != 0);

        if ((pxe->size == 1 || vm_is_pxe_valid(pxe) == FALSE) &&
            is_need_to_map_on_this_level == FALSE &&
            i < 3 &&
            has_pages_to_allocate) {
            //kernel_msg("Allocate table[%u]\n", i);
            
            PageXEntry* page_table = vm_alloc_page_table();

            if (page_table == NULL) return KERNEL_ERROR;

            vm_config_page_table_entry(pxe, (uint64_t)page_table, flags & (~VMMAP_USE_LARGE_PAGES));
        }
        else if (i < 3 && is_need_to_map_on_this_level == FALSE && has_pages_to_allocate) {
            vm_allow_pxe_flags(pxe, flags);
        }

        if (is_need_to_map_on_this_level) {
            //kernel_msg("Need to map[%u][%u] -> %x\n", i, ((uint64_t)pxe & 0xFFF) / 8, phys_address);
            // Check if need to free allocated page tables
            if (i < 3 && pxe->present == 1 && pxe->size != 1) vm_free_page_table((PageXEntry*)((uint64_t)pxe->page_ppn << 12));

            --i;

            vm_config_page_table_entry(pxe, (uint64_t)phys_address, flags);
            phys_address += level_size_table[i];
            virt_address += level_size_table[i];

            --pages_by_size_count[i];

            // Check if it is not the last entry in table 
            if (((uint64_t)pxe & 0xFFF) / 8 < 511) {
                ++pxe;
            }
            else {
                // Back to previouse level
                //kernel_msg("Back [%u -> %u][%u]\n", i + 1, i, (uint64_t)pxe & 0xFFF);
                pxe = vm_get_page_x_entry(virt_address, i);

                --i;
                offset_shift += 9;
            }
        }
        else if (i < 3) {
            pxe = (PageXEntry*)((uint64_t)pxe->page_ppn << 12) + ((virt_address >> offset_shift) & 0x1FF);

            //kernel_msg("Next entry [%u]: %x\n", i, (uint64_t)pxe);

            offset_shift -= 9;
        }
    }

    //kernel_msg("Mapped: %x:%x\n", virt_address - (PAGE_BYTE_SIZE * pages_count), phys_address - (PAGE_BYTE_SIZE * pages_count));

    return KERNEL_OK;
}