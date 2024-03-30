#include "vm.h"

#include <bootboot.h>

#include "assert.h"
#include "bitmap_mem_alloc.h"

#include "cpu/regs.h"

#include "logger.h"
#include "mem.h"

extern BOOTBOOT bootboot;

extern uint64_t kernel_elf_start;
extern uint64_t kernel_elf_end;

KernelAddressSpace kernel_addr_space;

// PML4
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageMapLevel4Entry vm_pml4[PAGE_TABLE_MAX_SIZE];

// PDPT
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageDirPtrEntry vm_low_pdpt[PAGE_TABLE_MAX_SIZE];
ATTR_ALIGN(PAGE_BYTE_SIZE)
PageDirPtrEntry vm_high_pdpt[PAGE_TABLE_MAX_SIZE];

static BitmapMemoryAllocator vm_page_table_pool;
static uint64_t vm_kernel_virt_to_phys_offset = 0;

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

static MMapEnt find_first_suitable_mmap_block(MMapEnt* begin_entry, const size_t entries_count, const size_t pages_count) {
    for (size_t i = 0; i < entries_count - (((uint64_t)begin_entry - (uint64_t)&bootboot.mmap.ptr) / sizeof(MMapEnt)); ++i) {
        MMapEnt* entry = begin_entry + i;

        if (MMapEnt_Type(entry) & (MMAP_FREE | MMAP_USED) == 0 || MMapEnt_Size(entry) < pages_count * PAGE_BYTE_SIZE) continue;

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

// Conver any kernel space address from virtual to physical
static inline uint64_t vm_kernel_virt_to_phys(const uint64_t kernel_virt_address) {
    return kernel_virt_address + vm_kernel_virt_to_phys_offset;
}

static void vm_config_page_table_entry(PageXEntry* page_table_entry, const uint64_t redirection_base, VMMapFlags flags) {
    page_table_entry->present               = 1;
    page_table_entry->writeable             = ((flags & VMMAP_WRITE) != 0);
    page_table_entry->user_access           = ((flags & VMMAP_USER_ACCESS) != 0);
    page_table_entry->size                  = ((flags & VMMAP_USE_LARGE_PAGES) != 0);
    page_table_entry->cache_disabled        = ((flags & VMMAP_CACHE_DISABLED) != 0);
    page_table_entry->write_through         = ((flags & VMMAP_WRITE_THROW) != 0);
    page_table_entry->page_ppn              = (redirection_base >> 12);
    page_table_entry->execution_disabled    = ((flags & VMMAP_EXEC) == 0);
}

static void vm_init_page_tables() {
    // Init with zeroes
    vm_init_page_table(vm_pml4);
    vm_init_page_table(vm_low_pdpt);
    vm_init_page_table(vm_high_pdpt);

    // Low half
    vm_config_page_table_entry(&vm_pml4[0],
                            vm_kernel_virt_to_phys((uint64_t)&vm_low_pdpt),
                            VMMAP_USER_ACCESS | VMMAP_EXEC | VMMAP_WRITE);

    // High half
    vm_config_page_table_entry(&vm_pml4[PAGE_TABLE_MAX_SIZE - 1],
                            vm_kernel_virt_to_phys((uint64_t)&vm_high_pdpt),
                            VMMAP_EXEC | VMMAP_WRITE);
}

#define VM_MEMMAP_PHYS_ADDRESS(entry_ptr) ((uint64_t)((entry_ptr)->compact_phys_address) << 12)

static inline void config_next_memmap_entry(
    VMMemoryMapEntry* vm_memmap_entry,
    const MMapEnt* boot_memmap_entry,
    const uint8_t boot_entry_type) {
    (vm_memmap_entry - 1)->pages_count =
        (uint32_t)((MMapEnt_Ptr(boot_memmap_entry) - VM_MEMMAP_PHYS_ADDRESS(vm_memmap_entry - 1)) / PAGE_BYTE_SIZE);

    vm_memmap_entry->compact_phys_address = (MMapEnt_Ptr(boot_memmap_entry) >> 12);
    vm_memmap_entry->type = (boot_entry_type == MMAP_FREE ? VMMEM_TYPE_FREE : VMMEM_TYPE_DEV);
}

static void vm_init_memory_map(VMMemoryMap* memory_map, MMapEnt* boot_memory_map, const size_t entries_count) {
    const uint32_t pool_pages_count = div_with_roundup(((entries_count + 1) * sizeof(VMMemoryMapEntry)), PAGE_BYTE_SIZE);
    const MMapEnt memmap_entries_pool = find_first_suitable_mmap_block(boot_memory_map, entries_count, pool_pages_count + 1);

    if (memmap_entries_pool.size == 0) return;

    memory_map->entries = (VMMemoryMapEntry*)(memmap_entries_pool.ptr + MMapEnt_Size(&memmap_entries_pool) - ((uint64_t)pool_pages_count * PAGE_BYTE_SIZE));
    memory_map->count = 1;

    uint32_t begin_entry_idx = 0;
    uint8_t prev_entry_type = 0;
    MMapEnt* prev_entry = NULL;

    for (uint32_t i = 0; i < entries_count; ++i) {
        const uint8_t curr_entry_type =
            (MMapEnt_Type(boot_memory_map + i) == MMAP_FREE || MMapEnt_Type(boot_memory_map + i) == MMAP_USED) ?
            MMAP_FREE : MMapEnt_Type(boot_memory_map + i);

        if (i == 0) {
            memory_map->entries->compact_phys_address = 0;
            memory_map->entries->type = (curr_entry_type == MMAP_FREE ? VMMEM_TYPE_FREE : VMMEM_TYPE_DEV);

            prev_entry_type = curr_entry_type;
            prev_entry = boot_memory_map;

            continue;
        }

        VMMemoryMapEntry* curr_vm_memmap_entry = &memory_map->entries[memory_map->count - 1];

        if (MMapEnt_Ptr(prev_entry) + MMapEnt_Size(prev_entry) == MMapEnt_Ptr(boot_memory_map + i)) {
            if (curr_entry_type != MMapEnt_Type(prev_entry) &&
                !(curr_entry_type == MMAP_FREE && MMapEnt_Type(prev_entry) == MMAP_USED)) {
                config_next_memmap_entry(&memory_map->entries[memory_map->count++], boot_memory_map + i, curr_entry_type);
            }
        }
        else {
            if (curr_entry_type != MMAP_FREE || prev_entry_type != MMAP_FREE) {
                if (prev_entry_type == MMAP_FREE) {
                    config_next_memmap_entry(&memory_map->entries[memory_map->count++], boot_memory_map + i, curr_entry_type);
                }
                else {
                    const uint64_t mem_block_end = MMapEnt_Ptr(prev_entry) + MMapEnt_Size(prev_entry);
                    curr_vm_memmap_entry->pages_count = MMapEnt_Size(prev_entry) / PAGE_BYTE_SIZE;

                    if (curr_entry_type == MMAP_FREE) {
                        memory_map->entries[memory_map->count].compact_phys_address = (uint32_t)(mem_block_end >> 12);
                        memory_map->entries[memory_map->count++].type = VMMEM_TYPE_FREE;
                    }
                    else {
                        // Need to insert free block between previouse and current blocks
                        memory_map->entries[memory_map->count].compact_phys_address = (uint32_t)(mem_block_end >> 12);
                        memory_map->entries[memory_map->count].pages_count = (MMapEnt_Ptr(boot_memory_map + i) - mem_block_end) / PAGE_BYTE_SIZE;
                        memory_map->entries[memory_map->count++].type = VMMEM_TYPE_FREE;

                        config_next_memmap_entry(&memory_map->entries[memory_map->count++], boot_memory_map + i, curr_entry_type);
                    }
                }
            }
        }

        if (i == entries_count - 1) {
            memory_map->entries[memory_map->count - 1].pages_count =
                ((MMapEnt_Ptr(boot_memory_map + i) + MMapEnt_Size(boot_memory_map + i)) -
                VM_MEMMAP_PHYS_ADDRESS(memory_map->entries + memory_map->count - 1)) / PAGE_BYTE_SIZE;

            break;
        }

        prev_entry_type = curr_entry_type;
        prev_entry = boot_memory_map + i;
    }
}

static void insert_memmap_entry(VMMemoryMap* memory_map,
    const uint64_t mem_phys_address,
    const uint32_t mem_pages_count,
    const uint8_t type) {
    kassert((mem_phys_address & 0xFFF) == 0 && mem_pages_count > 0);

    const uint64_t mem_end_phys_address = mem_phys_address + ((uint64_t)mem_pages_count * PAGE_BYTE_SIZE);

    for (uint32_t i = 0; i < memory_map->count; ++i) {
        const uint64_t begin_phys_address = VM_MEMMAP_PHYS_ADDRESS(memory_map->entries + i);
        const uint64_t end_phys_address = begin_phys_address + ((uint64_t)memory_map->entries[i].pages_count * PAGE_BYTE_SIZE);

        if (begin_phys_address <= mem_phys_address && end_phys_address >= mem_end_phys_address) {
            const uint64_t begin_offset = mem_phys_address - begin_phys_address;
            const uint64_t end_offset = end_phys_address - mem_end_phys_address;

            if (begin_offset == 0 && end_offset == 0) {
                memory_map->entries[i].type = type;
                break;
            }

            const uint32_t count_of_new_entries = (begin_offset > 0 ? 1 : 0) + (end_offset > 0 ? 1 : 0);

            // Resize array
            for (uint32_t j = memory_map->count + (count_of_new_entries - 1); j > i + count_of_new_entries; --j) {
                memory_map->entries[j] = memory_map->entries[j - count_of_new_entries];
            }

            if (begin_offset == 0) {
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_end_phys_address >> 12);
                memory_map->entries[i + 1].pages_count = memory_map->entries[i].pages_count - mem_pages_count;
                memory_map->entries[i].pages_count = mem_pages_count;
                memory_map->entries[i].type = type;
            }
            else if (end_offset == 0) {
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_phys_address >> 12);
                memory_map->entries[i + 1].pages_count = mem_pages_count;
                memory_map->entries[i + 1].type = type;
                memory_map->entries[i].pages_count -= mem_pages_count;
            }
            else {
                const uint32_t temp_pages_count = memory_map->entries[i].pages_count;

                memory_map->entries[i].pages_count = (uint32_t)(begin_offset / PAGE_BYTE_SIZE);
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_phys_address >> 12);
                memory_map->entries[i + 1].pages_count = mem_pages_count;
                memory_map->entries[i + 1].type = type;
                memory_map->entries[i + 2].compact_phys_address = (uint32_t)(mem_end_phys_address >> 12);
                memory_map->entries[i + 2].pages_count = temp_pages_count - memory_map->entries[i].pages_count - mem_pages_count;
            }

            memory_map->count += count_of_new_entries;
            break;
        }
    }
}

void log_memory_map(const VMMemoryMap* memory_map) {
    for (uint32_t i = 0; i < memory_map->count; ++i) {
        VMMemoryMapEntry* curr_entry = memory_map->entries + i;

        const char* type_str = NULL;

        switch (curr_entry->type)
        {
        case VMMEM_TYPE_FREE: type_str = "FREE"; break;
        case VMMEM_TYPE_USED: type_str = "USED"; break;
        case VMMEM_TYPE_DEV: type_str = "DEV"; break;
        case VMMEM_TYPE_KERNEL: type_str = "KERNEL"; break;
        case VMMEM_TYPE_ALLOC: type_str = "ALLOCATED"; break;
        default:
            break;
        }

        kernel_msg("Memmap entry: %x; size: %x; type: %s\n",
            ((uint64_t)curr_entry->compact_phys_address << 12),
            (uint64_t)curr_entry->pages_count * PAGE_BYTE_SIZE,
            type_str);
    }
}

Status init_virtual_memory(MMapEnt* boot_memory_map, const size_t entries_count, VMMemoryMap* out_memory_map) {
    kassert(boot_memory_map != NULL && entries_count > 0);

    kernel_addr_space.segments.virt_address = (uint64_t)&kernel_elf_start;
    vm_kernel_virt_to_phys_offset = get_phys_address(kernel_addr_space.segments.virt_address) - kernel_addr_space.segments.virt_address;

    kernel_addr_space.segments.phys_address = vm_kernel_virt_to_phys(kernel_addr_space.segments.virt_address);
    kernel_addr_space.segments.size = div_with_roundup((uint64_t)&kernel_elf_end - (uint64_t)&kernel_elf_start, PAGE_BYTE_SIZE) * PAGE_BYTE_SIZE;

#ifdef KDEBUG
    kernel_msg("Kernel: %x\n", get_phys_address((uint64_t)&kernel_elf_start));
    kernel_msg("Kernel size: %u KB (%u MB)\n", kernel_addr_space.segments.size / KB_SIZE, kernel_addr_space.segments.size / MB_SIZE);
    kernel_msg("Framebuffer: %x\n", get_phys_address((uint64_t)BOOTBOOT_FB));
    kernel_msg("Kernel virtual address space offset: %x\n", vm_kernel_virt_to_phys_offset);
#endif

    // Init pages pool
    const MMapEnt pages_pool_mmap_entry =
        find_first_suitable_mmap_block(boot_memory_map, entries_count, PAGE_TABLE_POOL_TABLES_COUNT + 1);

    if (pages_pool_mmap_entry.size == 0) {
        error_str = "Not found suitable memory block for paging tables pool";
        return KERNEL_ERROR;
    }

    vm_page_table_pool = bma_create(pages_pool_mmap_entry.ptr, (PAGE_TABLE_POOL_TABLES_COUNT + 1) * PAGE_BYTE_SIZE, PAGE_BYTE_SIZE);
    
    if (vm_page_table_pool.memory_pool == NULL) {
        error_str = "Failuer while initialization page table pool";
        return KERNEL_ERROR;
    }

    vm_init_page_tables();
    vm_init_memory_map(out_memory_map, boot_memory_map, entries_count);

    if (out_memory_map->count == 0) {
        error_str = "Memory map initialization failed";
        return KERNEL_ERROR;
    }

    insert_memmap_entry(out_memory_map,
        kernel_addr_space.segments.phys_address,
        kernel_addr_space.segments.size / PAGE_BYTE_SIZE,
        VMMEM_TYPE_KERNEL);

    insert_memmap_entry(out_memory_map,
        (uint64_t)vm_page_table_pool.memory_pool,
        vm_page_table_pool.capacity,
        VMMEM_TYPE_ALLOC);

    // Replace and map stack
    const MMapEnt stack_mmap_entry =
        find_first_suitable_mmap_block(boot_memory_map, entries_count, KERNEL_STACK_SIZE / PAGE_BYTE_SIZE);

    if (stack_mmap_entry.size == 0) {
        error_str = "Not found suitable memory block for replacing stack";
        return KERNEL_ERROR;
    }

    kernel_addr_space.stack.phys_address = stack_mmap_entry.ptr;
    kernel_addr_space.stack.virt_address = (UINT64_MAX - KERNEL_STACK_SIZE) + 1;
    kernel_addr_space.stack.size = KERNEL_STACK_SIZE;

    const void* stack_src_virt_ptr = (void*)((UINT64_MAX - (uint64_t)initstack) + 1);

    //Map 8GB physical identity
    vm_map_phys_to_virt(0x0,
                        0x0,
                        div_with_roundup(8 * GB_SIZE, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));

    // Map framebuffer
    vm_map_phys_to_virt(bootboot.fb_ptr,
                        BOOTBOOT_FB,
                        div_with_roundup(bootboot.fb_size, (2 * MB_SIZE)) * PAGES_PER_2MB,
                        (VMMAP_FORCE | VMMAP_WRITE_THROW | VMMAP_CACHE_DISABLED | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));

    // Map bootboot
    vm_map_phys_to_virt(get_phys_address((uint64_t)&bootboot),
                        (uint64_t)&bootboot,
                        div_with_roundup(bootboot.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_WRITE));

    // Map kernel
    vm_map_phys_to_virt(kernel_addr_space.segments.phys_address,
                        kernel_addr_space.segments.virt_address,
                        div_with_roundup(kernel_addr_space.segments.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE));

    // Map stack
    vm_map_phys_to_virt(get_phys_address((uint64_t)stack_src_virt_ptr),
                        (uint64_t)stack_src_virt_ptr,
                        kernel_addr_space.stack.size / PAGE_BYTE_SIZE,
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));

    log_memory_page_tables((PageMapLevel4Entry*)vm_kernel_virt_to_phys((uint64_t)&vm_pml4));

    // Enable OS paging
    cpu_set_pml4((PageMapLevel4Entry*)vm_kernel_virt_to_phys((uint64_t)&vm_pml4));
    kernel_warn("OS Page tables enabled\n");

    return KERNEL_OK;
}

PageXEntry* vm_alloc_page_table() {
    PageXEntry* page_table = bma_alloc(&vm_page_table_pool);

    if (page_table == NULL) {
        error_str = "Page table pool is empty";
        return NULL;
    }

    vm_init_page_table(page_table);

    return page_table;
}

// Takes physical address
void vm_free_page_table(PageXEntry* page_table) {
    kassert(page_table != NULL);

    bma_free((void*)page_table, &vm_page_table_pool);
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

static inline void vm_prioritize_pxe_flags(PageXEntry* pxe, VMMapFlags flags) {
    pxe->present            = 1;
    pxe->writeable          |= ((flags & VMMAP_WRITE) != 0);
    pxe->user_access        |= ((flags & VMMAP_USER_ACCESS) != 0);
    pxe->execution_disabled &= ((flags & VMMAP_EXEC) == 0);
}

static void vm_remap_large_page(PageXEntry* pxe, PageXEntry* child_pxe, VMMapFlags flags, const uint8_t level) {
    static const uint64_t level_size_table[2] = { (2 * MB_SIZE), PAGE_BYTE_SIZE };

    uint64_t phys_address = ((uint64_t)pxe->page_ppn << 12);

    pxe->size = 0;
    pxe->page_ppn = ((uint64_t)child_pxe >> 12);

    for (uint32_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        child_pxe[i].present = 1;
        child_pxe[i].writeable = (pxe->writeable | (flags & VMMAP_WRITE));
        child_pxe[i].user_access = (pxe->user_access | (flags & VMMAP_USER_ACCESS));
        child_pxe[i].execution_disabled = (pxe->execution_disabled & ((flags & VMMAP_EXEC) == 0));
        child_pxe[i].write_through = pxe->write_through;
        child_pxe[i].cache_disabled = pxe->cache_disabled;
        child_pxe[i].size = (level == 1 ? 0 : 1);
        child_pxe[i].page_ppn = (phys_address >> 12);

        phys_address += level_size_table[level];
    }
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

            if (pxe->size == 1) {
                kassert(i > 0);
                vm_remap_large_page(pxe, page_table, flags, i - 1);
            }
            else {
                vm_config_page_table_entry(pxe, (uint64_t)page_table, flags & (~VMMAP_USE_LARGE_PAGES));
            }
        }
        else if (i < 3 && is_need_to_map_on_this_level == FALSE && has_pages_to_allocate) {
            // Prioritize high page x entry flags to sure that flags are compatible with mapping requirements
            vm_prioritize_pxe_flags(pxe, flags);
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
            offset_shift -= 9;

            //kernel_msg("Next entry [%u]: %x\n", i, (uint64_t)pxe);
        }
    }

    //kernel_msg("Mapped: %x:%x\n", virt_address - (PAGE_BYTE_SIZE * pages_count), phys_address - (PAGE_BYTE_SIZE * pages_count));

    return KERNEL_OK;
}