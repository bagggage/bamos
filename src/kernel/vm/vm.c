#include "vm.h"

#include "assert.h"
#include "buddy_page_alloc.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "object_mem_alloc.h"

#include "cpu/feature.h"
#include "cpu/regs.h"

#include "proc/local.h"

#define PAGE_TABLE_POOL_TABLES_COUNT 511UL

extern BOOTBOOT bootboot;
extern uint8_t  environment;

extern uint64_t kernel_elf_start;
extern uint64_t kernel_elf_end;

static KernelAddressSpace kernel_addr_space;
static VMHeap kernel_heap;

static VMPageList _vm_phys_pages_oma;

static ObjectMemoryAllocator vm_page_table_oma;
static ObjectMemoryAllocator vm_page_frame_oma;
static uint64_t vm_kernel_virt_to_phys_offset = 0;

// Linker setted stack size
extern uint64_t initstack[];
extern uint8_t fb[];

static Status _vm_map_phys_to_virt(uint64_t phys_address,
    uint64_t virt_address, PageMapLevel4Entry* pml4,
    const size_t pages_count, VMMapFlags flags);

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

        if (MMapEnt_Ptr(entry) == 0 || MMapEnt_IsFree(entry) == FALSE ||
            (MMapEnt_Size(entry) < pages_count * PAGE_BYTE_SIZE))
            continue;

        MMapEnt result = *entry;
        result.size = pages_count * PAGE_BYTE_SIZE;

        return result;
    }

    return (MMapEnt){ 0, 0 };
}

static inline bool_t is_virt_addr_valid(const uint64_t virt_address) {
    const VirtualAddress* virtual_addr = (const VirtualAddress*)&virt_address;

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
    page_table_entry->global                = page_table_entry->size && ((flags & VMMAP_GLOBAL) != 0);
    page_table_entry->cache_disabled        = ((flags & VMMAP_CACHE_DISABLED) != 0);
    page_table_entry->write_through         = ((flags & VMMAP_WRITE_THROW) != 0);
    page_table_entry->page_ppn              = (redirection_base >> 12);
    page_table_entry->execution_disabled    = ((flags & VMMAP_EXEC) == 0);
}

static void vm_map_high_kernel(PageMapLevel4Entry* pml4) {
    // Map framebuffer
    _vm_map_phys_to_virt(bootboot.fb_ptr,
                        (uint64_t)&fb,
                        pml4,
                        div_with_roundup(div_with_roundup(bootboot.fb_size, MB_SIZE * 2) * MB_SIZE * 2, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_WRITE_THROW | VMMAP_CACHE_DISABLED | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES | VMMAP_GLOBAL));

    // Map bootboot
    _vm_map_phys_to_virt(get_phys_address((uint64_t)&bootboot),
                        (uint64_t)&bootboot,
                        pml4,
                        div_with_roundup(bootboot.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_GLOBAL));

    _vm_map_phys_to_virt(get_phys_address((uint64_t)&environment),
                        (uint64_t)&environment,
                        pml4,
                        1,
                        (VMMAP_FORCE | VMMAP_GLOBAL));

    // Map kernel
    _vm_map_phys_to_virt(kernel_addr_space.segments.phys_address,
                        kernel_addr_space.segments.virt_address,
                        pml4,
                        div_with_roundup(kernel_addr_space.segments.size, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE | VMMAP_GLOBAL));

    // Map stack
    for (uint32_t i = 0; i < bootboot.numcores; ++i) {
        if (((uint64_t)i * (uint64_t)&initstack) % PAGE_BYTE_SIZE != 0) continue;

        const uint64_t core_stack_virt_addr = (UINT64_MAX - ((i + 1) * (uint64_t)&initstack)) + 1;

        _vm_map_phys_to_virt(get_phys_address(core_stack_virt_addr),
                            core_stack_virt_addr,
                            pml4,
                            1,
                            (VMMAP_FORCE | VMMAP_EXEC | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES | VMMAP_GLOBAL));
    }
}

static void vm_init_page_tables() {
    g_proc_local.kernel_page_table = vm_alloc_page_table();

    //Map DMA physical identity
    vm_map_phys_to_virt(0x0,
                        0x0,
                        div_with_roundup(GB_SIZE * 16, PAGE_BYTE_SIZE),
                        (VMMAP_FORCE | VMMAP_WRITE | VMMAP_EXEC | VMMAP_USE_LARGE_PAGES | VMMAP_GLOBAL));

    vm_map_high_kernel(g_proc_local.kernel_page_table);
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
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_end_phys_address / PAGE_BYTE_SIZE);
                memory_map->entries[i + 1].pages_count = memory_map->entries[i].pages_count - mem_pages_count;
                memory_map->entries[i + 1].type = memory_map->entries[i].type;
                memory_map->entries[i].pages_count = mem_pages_count;
                memory_map->entries[i].type = type;
            }
            else if (end_offset == 0) {
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_phys_address / PAGE_BYTE_SIZE);
                memory_map->entries[i + 1].pages_count = mem_pages_count;
                memory_map->entries[i + 1].type = type;
                memory_map->entries[i].pages_count -= mem_pages_count;
            }
            else {
                const uint32_t temp_pages_count = memory_map->entries[i].pages_count;

                memory_map->entries[i].pages_count = (uint32_t)(begin_offset / PAGE_BYTE_SIZE);
                memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_phys_address / PAGE_BYTE_SIZE);
                memory_map->entries[i + 1].pages_count = mem_pages_count;
                memory_map->entries[i + 1].type = type;
                memory_map->entries[i + 2].type = memory_map->entries[i].type;
                memory_map->entries[i + 2].compact_phys_address = (uint32_t)(mem_end_phys_address / PAGE_BYTE_SIZE);
                memory_map->entries[i + 2].pages_count = temp_pages_count - memory_map->entries[i].pages_count - mem_pages_count;
            }

            memory_map->count += count_of_new_entries;
            break;
        }
        else if (begin_phys_address > mem_phys_address) {
            i--;

            for (uint32_t j = memory_map->count; j > i + 1; --j) {
                memory_map->entries[j] = memory_map->entries[j - 1];
            }

            memory_map->entries[i + 1].compact_phys_address = (uint32_t)(mem_phys_address / PAGE_BYTE_SIZE);
            memory_map->entries[i + 1].pages_count = mem_pages_count;
            memory_map->entries[i + 1].type = type;

            memory_map->count++;
            break;
        }
    }
}

static void _map_linear_phys_gb(const uint64_t phys_address) {
    const uint64_t gb_aligned_address = GB_SIZE * (phys_address / GB_SIZE);

    _vm_map_phys_to_virt(
            gb_aligned_address,
            gb_aligned_address,
            cpu_get_current_pml4(),
            GB_SIZE / PAGE_BYTE_SIZE,
            (VMMAP_FORCE | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES));
}

// Additional regions that will be used for kernel segments and pages pool
#define VM_MEMMAP_ADD_COUNT 3

static void vm_init_memory_map(VMMemoryMap* memory_map, MMapEnt* boot_memory_map, const size_t entries_count) {
    const uint32_t pool_pages_count =
        div_with_roundup(((entries_count + VM_MEMMAP_ADD_COUNT) * sizeof(VMMemoryMapEntry)), PAGE_BYTE_SIZE);
    const MMapEnt memmap_entries_pool = find_first_suitable_mmap_block(boot_memory_map, entries_count, pool_pages_count);

    if (memmap_entries_pool.size == 0) return;

    if (get_phys_address(MMapEnt_Ptr(&memmap_entries_pool)) != MMapEnt_Ptr(&memmap_entries_pool)) {
        kernel_debug("Memmap maping...\n");
        _map_linear_phys_gb(MMapEnt_Ptr(&memmap_entries_pool));
    }

    memory_map->entries = (VMMemoryMapEntry*)(memmap_entries_pool.ptr + MMapEnt_Size(&memmap_entries_pool) - ((uint64_t)pool_pages_count * PAGE_BYTE_SIZE));
    memory_map->count = entries_count;

    uint32_t idx = 0;

    for (uint32_t i = 0; i < entries_count; ++i) {
        MMapEnt* curr_entry = boot_memory_map + i;

        if (MMapEnt_Ptr(curr_entry) % PAGE_BYTE_SIZE != 0) {
            memory_map->count = i;
            break;
        }

        const uint8_t curr_entry_type = MMapEnt_Type(curr_entry);

        memory_map->entries[idx].compact_phys_address = (uint32_t)(MMapEnt_Ptr(curr_entry) / PAGE_BYTE_SIZE);
        memory_map->entries[idx].pages_count = MMapEnt_Size(curr_entry) / PAGE_BYTE_SIZE;

        switch (curr_entry_type)
        {
        case MMAP_FREE:
            memory_map->entries[idx].type = VMMEM_TYPE_FREE;
            memory_map->total_pages_count += memory_map->entries[i].pages_count;
            break;
        case MMAP_USED:
            memory_map->entries[idx].type = VMMEM_TYPE_USED;
            break;
        case MMAP_ACPI: FALLTHROUGH;
        case MMAP_MMIO:
            memory_map->entries[idx].type = VMMEM_TYPE_DEV;
            break;
        default:
            kassert(FALSE);
            break;
        }

        idx++;
    }

    insert_memmap_entry(memory_map, (uint64_t)memory_map->entries, pool_pages_count, VMMEM_TYPE_ALLOC);
}

VMMemoryMapEntry* _vm_boot_alloc(VMMemoryMap* memory_map, const uint32_t pages_count) {
    for (uint32_t i = 0; i < memory_map->count; ++i) {
        if (memory_map->entries[i].compact_phys_address != 0 &&
            memory_map->entries[i].pages_count >= pages_count &&
            memory_map->entries[i].type == VMMEM_TYPE_FREE) {
            insert_memmap_entry(memory_map,
                (uint64_t)memory_map->entries[i].compact_phys_address * PAGE_BYTE_SIZE,
                pages_count, VMMEM_TYPE_ALLOC);

            return &memory_map->entries[i];
        }
    }

    return NULL;
}

PageMapLevel4Entry* vm_get_kernel_pml4() {
    return g_proc_local.kernel_page_table;
}

VMHeap* vm_get_kernel_heap() {
    return &kernel_heap;
}

void log_memory_map(const VMMemoryMap* memory_map) {
    for (uint32_t i = 0; i < memory_map->count; ++i) {
        const VMMemoryMapEntry* curr_entry = memory_map->entries + i;

        const char* type_str = NULL;

        switch (curr_entry->type)
        {
        case VMMEM_TYPE_FREE:   type_str = "FREE"; break;
        case VMMEM_TYPE_USED:   type_str = "USED"; break;
        case VMMEM_TYPE_DEV:    type_str = "DEV"; break;
        case VMMEM_TYPE_KERNEL: type_str = "KERNEL"; break;
        case VMMEM_TYPE_ALLOC:  type_str = "ALLOCATED"; break;
        default: kassert(FALSE); break;
        }

        kernel_msg("Memmap entry: %x; size: %x; type: %s\n",
            ((uint64_t)curr_entry->compact_phys_address * PAGE_BYTE_SIZE),
            (uint64_t)curr_entry->pages_count * PAGE_BYTE_SIZE,
            type_str);
    }
}

Status init_virtual_memory(MMapEnt* boot_memory_map, const size_t entries_count, VMMemoryMap* out_memory_map) {
    kassert(boot_memory_map != NULL && entries_count > 0 && out_memory_map != NULL);

    kernel_addr_space.segments.virt_address = (uint64_t)&kernel_elf_start;
    vm_kernel_virt_to_phys_offset = get_phys_address(kernel_addr_space.segments.virt_address) - kernel_addr_space.segments.virt_address;

    kernel_addr_space.segments.phys_address = vm_kernel_virt_to_phys(kernel_addr_space.segments.virt_address);
    kernel_addr_space.segments.size = div_with_roundup((uint64_t)&kernel_elf_end - (uint64_t)&kernel_elf_start, PAGE_BYTE_SIZE) * PAGE_BYTE_SIZE;

#ifdef KDEBUG
    kernel_msg("Kernel: %x\n", get_phys_address((uint64_t)&kernel_elf_start));
    kernel_msg("Kernel size: %u KB (%u MB)\n", kernel_addr_space.segments.size / KB_SIZE, kernel_addr_space.segments.size / MB_SIZE);
    kernel_msg("Framebuffer: %x\n", get_phys_address((uint64_t)BOOTBOOT_FB));
#endif

    vm_init_memory_map(out_memory_map, boot_memory_map, entries_count);

    if (out_memory_map->count == 0) {
        error_str = "Memory map initialization failed";
        return KERNEL_ERROR;
    }

    insert_memmap_entry(out_memory_map,
        kernel_addr_space.segments.phys_address,
        kernel_addr_space.segments.size / PAGE_BYTE_SIZE,
        VMMEM_TYPE_KERNEL);

    kernel_addr_space.stack.size =
        div_with_roundup((uint64_t)&initstack * (uint64_t)bootboot.numcores, PAGE_BYTE_SIZE) * PAGE_BYTE_SIZE;
    kernel_addr_space.stack.virt_address = UINT64_MAX - kernel_addr_space.stack.size + 1;
    kernel_addr_space.stack.phys_address = get_phys_address(kernel_addr_space.stack.virt_address);

    // Init pages pool
    const VMMemoryMapEntry* pages_pool_mmap_entry = _vm_boot_alloc(out_memory_map, PAGE_TABLE_POOL_TABLES_COUNT + 1);

    if (pages_pool_mmap_entry == NULL) {
        error_str = "Not found suitable memory block for paging tables pool";
        return KERNEL_ERROR;
    }

    if (get_phys_address((uint64_t)pages_pool_mmap_entry->compact_phys_address * PAGE_BYTE_SIZE) !=
        (uint64_t)pages_pool_mmap_entry->compact_phys_address * PAGE_BYTE_SIZE) {
        kernel_debug("VM Page tabels pool was remapped in boot page tabels\n");
        _map_linear_phys_gb((uint64_t)pages_pool_mmap_entry->compact_phys_address * PAGE_BYTE_SIZE);
    }

    VMPageFrame page_frame;

    page_frame.flags = (VMMAP_GLOBAL | VMMAP_WRITE | VMMAP_USE_LARGE_PAGES);
    page_frame.count = PAGE_TABLE_POOL_TABLES_COUNT + 1;
    page_frame.phys_pages.next = (ListHead*)&_vm_phys_pages_oma;
    page_frame.phys_pages.prev = (ListHead*)&_vm_phys_pages_oma;
    page_frame.virt_address = (uint64_t)pages_pool_mmap_entry->compact_phys_address * PAGE_BYTE_SIZE;

    _vm_phys_pages_oma.next = NULL;
    _vm_phys_pages_oma.prev = NULL;
    _vm_phys_pages_oma.phys_page_base = pages_pool_mmap_entry->compact_phys_address;

    vm_page_table_oma = _oma_manual_init(&page_frame, PAGE_TABLE_SIZE);

    if (vm_page_table_oma.bucket_capacity < PAGE_TABLE_POOL_TABLES_COUNT) {
        error_str = "VM Page table OMA: capacity is to small";
        return KERNEL_ERROR;
    }

    vm_heap_construct(&kernel_heap, KERNEL_HEAP_VIRT_ADDRESS);
    vm_init_page_tables();

    // Enable OS paging
    vm_setup_paging(g_proc_local.kernel_page_table);
    kernel_warn("OS Page tables enabled\n");

    return KERNEL_OK;
}

Status init_vm_allocator() {
    static VMPageList vm_frame_oma_phys_page;

    VMPageFrame frame;
    frame.phys_pages.next = (ListHead*)(void*)&vm_frame_oma_phys_page;
    frame.phys_pages.prev = (ListHead*)(void*)&vm_frame_oma_phys_page;

    // Allocate two pages
    vm_frame_oma_phys_page.phys_page_base = bpa_allocate_pages(2) / PAGE_BYTE_SIZE;

    if (((uint64_t)vm_frame_oma_phys_page.phys_page_base * PAGE_BYTE_SIZE) == INVALID_ADDRESS) {
        error_str = "VM Frame oma can't be allocated";
        return KERNEL_ERROR;
    }

    frame.count = 2;
    frame.virt_address = vm_heap_reserve(&kernel_heap, frame.count);
    frame.flags = (VMMAP_FORCE | VMMAP_WRITE);

    vm_map_phys_to_virt((uint64_t)vm_frame_oma_phys_page.phys_page_base * PAGE_BYTE_SIZE,
        frame.virt_address,
        2,
        frame.flags);

    vm_page_frame_oma = _oma_manual_init(&frame, sizeof(VMPageFrame));

#ifdef KDEBUG
    kernel_warn("VM Frame oma: %x (%x)\n", frame.virt_address, (uint64_t)vm_frame_oma_phys_page.phys_page_base * PAGE_BYTE_SIZE);
    kernel_warn("VM Frame oma bucket capacity: %u\n", vm_page_frame_oma.bucket_capacity);
#endif

    if (vm_init_heap_manager() == FALSE) {
        error_str = "VM: Failed to initialize heap manager";
        return KERNEL_ERROR;
    }

    return KERNEL_OK;
}

PageXEntry* vm_alloc_page_table() {
    PageXEntry* page_table = (PageXEntry*)oma_alloc(&vm_page_table_oma);

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

    oma_free((void*)page_table, &vm_page_table_oma);
}

static inline bool_t vm_is_pxe_valid(const PageXEntry* pxe) {
    return pxe->present && (pxe->size == 1 || pxe->page_ppn != 0 || pxe->writeable == 1);
}

PageXEntry* vm_get_page_x_entry(const uint64_t virt_address, unsigned int level) {
    kassert(level < 4);

    PageXEntry* pxe =
        (PageXEntry*)get_phys_address((uint64_t)g_proc_local.kernel_page_table) +
        (uint64_t)((const VirtualAddress*)(const void*)&virt_address)->p4_index;

    uint8_t offset_shift = 30;

    for (uint16_t i = 0; i < level; ++i) {
        pxe = (PageXEntry*)((uint64_t)pxe->page_ppn << 12) + ((*(const uint64_t*)&virt_address >> offset_shift) & 0x1FF);
        offset_shift -= 9;
    }

    return pxe;
}

PageXEntry* _get_page_x_entry(PageMapLevel4Entry* pml4, const uint64_t virt_address, unsigned int level) {
    kassert(level < 4);

    PageXEntry* pxe =
        (PageXEntry*)get_phys_address((uint64_t)pml4) +
        (uint64_t)((const VirtualAddress*)(const void*)&virt_address)->p4_index;

    uint8_t offset_shift = 30;

    for (uint16_t i = 0; i < level; ++i) {
        pxe = (PageXEntry*)((uint64_t)pxe->page_ppn * PAGE_BYTE_SIZE) + ((*(const uint64_t*)&virt_address >> offset_shift) & 0x1FF);
        offset_shift -= 9;
    }

    return pxe;
}

static inline void vm_prioritize_pxe_flags(PageXEntry* pxe, VMMapFlags flags) {
    pxe->present            = 1;
    pxe->writeable          |= ((flags & VMMAP_WRITE) != 0);
    pxe->user_access        |= ((flags & VMMAP_USER_ACCESS) != 0);
    pxe->execution_disabled &= ((flags & VMMAP_EXEC) == 0);
    pxe->cache_disabled     &= ((flags & VMMAP_CACHE_DISABLED) != 0);
    pxe->write_through      &= ((flags & VMMAP_WRITE_THROW) != 0);
}

static void vm_remap_large_page(PageXEntry* pxe, PageXEntry* child_pxe, VMMapFlags flags, const uint8_t level) {
    static const uint64_t level_size_table[2] = { (2 * MB_SIZE), PAGE_BYTE_SIZE };

    uint64_t phys_address = ((uint64_t)pxe->page_ppn * PAGE_BYTE_SIZE);

    pxe->size = 0;
    pxe->page_ppn = ((uint64_t)child_pxe / PAGE_BYTE_SIZE);

    for (uint32_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        child_pxe[i].present = 1;
        child_pxe[i].writeable = (pxe->writeable | (flags & VMMAP_WRITE));
        child_pxe[i].user_access = (pxe->user_access | (flags & VMMAP_USER_ACCESS));
        child_pxe[i].execution_disabled = (pxe->execution_disabled & ((flags & VMMAP_EXEC) == 0));
        child_pxe[i].write_through = pxe->write_through;
        child_pxe[i].cache_disabled = pxe->cache_disabled;
        child_pxe[i].size = (level == 1 ? 0 : 1);
        child_pxe[i].page_ppn = (phys_address / PAGE_BYTE_SIZE);

        phys_address += level_size_table[level];
    }
}

static Status _vm_map_phys_to_virt(uint64_t phys_address,
    uint64_t virt_address, PageMapLevel4Entry* pml4,
    const size_t pages_count, VMMapFlags flags) {
    kassert(phys_address <= MAX_PHYS_ADDRESS);
    kassert(pages_count < MAX_PAGE_BASE);

    if (is_virt_addr_valid(virt_address) == FALSE) return KERNEL_ERROR;

    static const uint64_t level_size_table[3] = { GB_SIZE, (2 * MB_SIZE), PAGE_BYTE_SIZE };

    if ((flags & VMMAP_USE_LARGE_PAGES) != 0 &&
        (phys_address % (PAGE_BYTE_SIZE * 512) != 0 ||
        ((phys_address & 0x1FF000) != (virt_address & 0x1FF000)))) {
        flags ^= VMMAP_USE_LARGE_PAGES;
    }

    uint32_t pages_by_size_count[4] = { 0, 0, pages_count, 0 };

    if ((flags & VMMAP_USE_LARGE_PAGES) != 0) {
        pages_by_size_count[0] = (pages_count * PAGE_BYTE_SIZE) / GB_SIZE; // 1GB
        pages_by_size_count[1] = ((pages_count * PAGE_BYTE_SIZE) / (2U * MB_SIZE)); // 2MB
        pages_by_size_count[2] -= (pages_by_size_count[1] * PAGE_TABLE_MAX_SIZE); // 4KB
        // the last pages count must always be 0, this entry exists only for checking

        pages_by_size_count[1] -= (pages_by_size_count[0] * PAGE_TABLE_MAX_SIZE);
    }

    // Debug
    //kernel_msg("(%x -> %x) 1GB: %u, 2MB: %u; 4KB: %u\n", phys_address, virt_address, pages_by_size_count[0], pages_by_size_count[1], pages_by_size_count[2]);

    uint32_t offset_shift = 39;

    PageXEntry* pxe = (PageXEntry*)pml4 + ((virt_address >> offset_shift) & 0x1FF);
    offset_shift -= 9;

    for (int i = 0; i < 4; ++i) {
        const bool_t is_need_to_map_on_this_level = (i != 0 && pages_by_size_count[i - 1] > 0);
        const bool_t has_pages_to_allocate = (i == 0 ?
            (pages_by_size_count[0] != 0 || *(uint64_t*)(pages_by_size_count + 1) != 0) :
            (*(uint64_t*)(pages_by_size_count + i) != 0)
        );

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
            if (i < 3 && pxe->present == 1 && pxe->size != 1) {
                vm_free_page_table((PageXEntry*)((uint64_t)pxe->page_ppn * PAGE_BYTE_SIZE));
            }

            --i;

            vm_config_page_table_entry(pxe, (uint64_t)phys_address, flags);

            kassert(pxe->size == 0 || (pxe->page_ppn & 0x1FF) == 0);

            phys_address += level_size_table[i];
            virt_address += level_size_table[i];

            --pages_by_size_count[i];

            // Check if it is not the last entry in table 
            if (((uint64_t)pxe & 0xFFF) / sizeof(PageXEntry) < 511) {
                ++pxe;
            }
            else {
                // Back to previouse level
                //kernel_msg("Back [%u -> %u][%u]\n", i + 1, i, (uint64_t)pxe & 0xFFF);
                pxe = _get_page_x_entry(pml4, virt_address, i);

                --i;
                offset_shift += 9;
            }
        }
        else if (i < 3) {
            pxe = (PageXEntry*)((uint64_t)pxe->page_ppn * PAGE_BYTE_SIZE) + ((virt_address >> offset_shift) & 0x1FF);
            offset_shift -= 9;

            //kernel_msg("Next entry [%u]: %x\n", i, (uint64_t)pxe);
        }
    }

    //kernel_msg("Mapped: %x:%x\n", virt_address - (PAGE_BYTE_SIZE * pages_count), phys_address - (PAGE_BYTE_SIZE * pages_count));

    return KERNEL_OK;
}

static inline uint32_t get_virt_addres_px_idx(const uint64_t virt_address, const uint8_t px) {
    return ((virt_address >> (12 + (9 * (uint32_t)px))) & 0x1FF);
}

static bool_t is_page_table_empty(const PageMapLevel4Entry* page_table) {
    for (uint32_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        if (vm_is_pxe_valid(page_table + i) != FALSE) return FALSE;
    }

    return TRUE;
}

void vm_unmap(const uint64_t virt_address, PageMapLevel4Entry* pml4, const uint32_t pages_count) {
    kassert(pml4 != NULL && pages_count > 0 && pages_count < INT32_MAX);

    const VirtualAddress* virt_addr = (const VirtualAddress*)(const void*)&virt_address;

    int32_t pages_to_unmap_count = pages_count;

    PageXEntry* pxe_stack[4] = { NULL, NULL, NULL, NULL };
    PageXEntry* pxe = pml4 + virt_addr->p4_index;

    for (uint32_t level = 4;;) {
    table_entries_unmap_pass:
        const uint32_t pxe_pages_count = 1 << ((level - 1) * 9);
        const uint32_t idx = ((uint64_t)pxe % PAGE_TABLE_SIZE) / sizeof(PageXEntry);

        pxe -= idx;

        for (uint32_t i = idx; i < PAGE_TABLE_MAX_SIZE && pages_to_unmap_count > 0; ++i) {
            if (pxe[i].size == 1 || level == 1) {
                *(uint64_t*)(pxe + i) = 0;
                pages_to_unmap_count -= pxe_pages_count;

                if (pages_to_unmap_count <= 0) break;
            }
            else {
                bool_t is_first_level_down = (pxe_stack[level - 1] == NULL);
                bool_t is_page_table_covered =
                    (is_first_level_down ?
                    (get_virt_addres_px_idx(virt_address, level - 2) == 0) : 
                    (TRUE));

                if (level == 2 && is_page_table_covered && (uint32_t)pages_to_unmap_count >= pxe_pages_count) {
                    vm_free_page_table((PageXEntry*)((uint64_t)pxe[i].page_ppn * PAGE_BYTE_SIZE));

                    *(uint64_t*)(pxe + i) = 0;
                    pages_to_unmap_count -= pxe_pages_count;

                    if (pages_to_unmap_count <= 0) break;
                }
                else {
                    pxe_stack[level - 1] = pxe + i;
                    pxe = (PageXEntry*)((uint64_t)pxe[i].page_ppn * PAGE_BYTE_SIZE);

                    level--;

                    if (is_first_level_down) {
                        pxe += get_virt_addres_px_idx(virt_address, level - 1);
                    }

                    goto table_entries_unmap_pass;
                }
            }
        }

        if (level == 4) break;

        level++;
        pxe = pxe_stack[level - 1];

        PageXEntry* child_pxe = (PageXEntry*)((uint64_t)pxe->page_ppn * PAGE_BYTE_SIZE);

        if (child_pxe != NULL && is_page_table_empty(child_pxe)) {
            vm_free_page_table(child_pxe);
            *(uint64_t*)pxe = 0;
        }

        pxe++;
    }
}

Status vm_map_phys_to_virt(uint64_t phys_address, uint64_t virt_address, const size_t pages_count, VMMapFlags flags) {
    return _vm_map_phys_to_virt(phys_address, virt_address, g_proc_local.kernel_page_table, pages_count, flags);
}

static uint32_t get_max_near_rank_of(const uint32_t number) {
    uint32_t rank = BPA_MAX_BLOCK_RANK - 1; 

    while (number < (1u << rank)) {
        rank--;
    }

    return rank;
}

static bool_t frame_push_phys_page(VMPageFrame* frame, const uint64_t phys_page) {
    VMPageList* node = oma_alloc(&vm_page_frame_oma);

    if (node == NULL) return FALSE;

    node->phys_page_base = (phys_page / PAGE_BYTE_SIZE);
    node->next = NULL;
    node->prev = NULL;

    if (frame->phys_pages.next == NULL) {
        frame->phys_pages.next = (ListHead*)(void*)node;
    }
    else {
        node->prev = (VMPageList*)(void*)frame->phys_pages.prev;
        frame->phys_pages.prev->next = (ListHead*)(void*)node;
    }

    frame->phys_pages.prev = (ListHead*)(void*)node;

    return TRUE;
}

static void frame_clear_phys_pages(VMPageFrame* frame) {
    VMPageList* page = (VMPageList*)(void*)frame->phys_pages.next;

    while (page != NULL) {
        VMPageList* temp_page = page;

        page = page->next;

        oma_free((void*)temp_page, &vm_page_frame_oma);
    }

    frame->phys_pages.next = NULL;
    frame->phys_pages.prev = NULL;
}

static void frame_free_phys_pages(VMPageFrame* frame) {
    uint32_t rank = get_max_near_rank_of(frame->count);
    uint32_t rank_pages_count = 1 << rank;
    uint32_t pages_to_free_count = frame->count;

    VMPageList* page = (VMPageList*)(void*)frame->phys_pages.next;

    while (page != NULL) {
        bpa_free_pages(page->phys_page_base * PAGE_BYTE_SIZE, rank);

        pages_to_free_count -= rank_pages_count;

        while (pages_to_free_count < rank_pages_count) {
            rank_pages_count >>= 1;
            rank--;
        }

        page = page->next;
    }

    frame_clear_phys_pages(frame);
    frame->count = 0;
}

uint64_t vm_find_free_virt_address(const PageMapLevel4Entry* pml4 ,const uint32_t pages_count) {
    const PageXEntry* pxe = pml4;
    uint64_t virt_address = 0;
    uint32_t temp_pages_count = 0;

    const PageXEntry* pxe_stack[4] = { NULL, NULL, NULL, pml4 };

    for (uint32_t level = 4; level > 0;) {
    table_entries_pass:
        const uint32_t pxe_pages_count = 1 << ((level - 1) * 9);
        const uint32_t idx = ((uint64_t)pxe % PAGE_TABLE_SIZE) / sizeof(PageXEntry);

        pxe -= idx;

        for (uint32_t i = idx; i < PAGE_TABLE_MAX_SIZE; ++i) {
            if (vm_is_pxe_valid(pxe + i) == FALSE) {
                temp_pages_count += pxe_pages_count;

                if (temp_pages_count >= pages_count) return virt_address;
            }
            else if (pxe[i].size == 1 || level == 1) {
                virt_address += (uint64_t)(pxe_pages_count + temp_pages_count) * PAGE_BYTE_SIZE;
                temp_pages_count = 0;
            }
            else {
                pxe_stack[level - 1] = pxe + i;
                pxe = (const PageXEntry*)((uint64_t)pxe[i].page_ppn * PAGE_BYTE_SIZE);

                level--;
                goto table_entries_pass;
            }
        }

        if (level == 4) break;

        level++;
        pxe = pxe_stack[level - 1] + 1;
    }

    return INVALID_ADDRESS;
}

static bool_t vm_map_page_frame(VMPageFrame* frame, PageMapLevel4Entry* pml4, VMMapFlags flags) {
    uint32_t rank_pages_count = 1 << get_max_near_rank_of(frame->count);
    uint32_t pages_to_map_count = frame->count;
    uint64_t virt_address = frame->virt_address;

    VMPageList* page = (VMPageList*)(void*)frame->phys_pages.next;

    while (page != NULL) {
        if (_vm_map_phys_to_virt((uint64_t)page->phys_page_base * PAGE_BYTE_SIZE,
                virt_address, pml4, rank_pages_count, flags) != KERNEL_OK) {
            return FALSE;
        }

        pages_to_map_count -= rank_pages_count;
        virt_address += ((uint64_t)rank_pages_count * PAGE_BYTE_SIZE);

        while (pages_to_map_count < rank_pages_count && rank_pages_count > 0) {
            rank_pages_count >>= 1;
        }

        page = page->next;
    }

    frame->flags = flags;

    return TRUE;
}

VMPageFrame vm_alloc_pages(const uint32_t pages_count, VMHeap* heap, PageMapLevel4Entry* pml4, VMMapFlags flags) {
    kassert(heap != NULL && pml4 != NULL && pages_count > 0);

    uint32_t rank = BPA_MAX_BLOCK_RANK - 1;
    uint32_t rank_pages_count = 1 << rank;

    VMPageFrame frame = { 0, 0, { NULL, NULL }, 0 };
    uint32_t temp_pages_count = pages_count;

    while (TRUE) {
        if (temp_pages_count >= rank_pages_count) {
            temp_pages_count -= rank_pages_count;

            uint64_t phys_address = bpa_allocate_pages(rank);

            if (phys_address == INVALID_ADDRESS) {
                frame_free_phys_pages(&frame);
                return frame;
            }
            else if (frame_push_phys_page(&frame, phys_address) == FALSE) {
                bpa_free_pages(phys_address ,rank);
                frame_free_phys_pages(&frame);
                return frame;
            }

            frame.count += rank_pages_count;

            if (frame.count == pages_count) break;

            kassert(frame.count < pages_count);
        }
        else {
            rank_pages_count >>= 1;
            rank--;
        }
    }

    frame.virt_address = vm_heap_reserve(heap, pages_count);

    if (vm_map_page_frame(&frame, pml4, flags) == FALSE) {
        frame_free_phys_pages(&frame);
        frame.count = 0;
        return frame;
    }

    return frame;
}

void vm_free_pages(VMPageFrame* frame, VMHeap* heap, PageMapLevel4Entry* pml4) {
    kassert(frame != NULL);

    vm_unmap(frame->virt_address, pml4, frame->count);
    vm_heap_release(heap, frame->virt_address, frame->count);

    frame_free_phys_pages(frame);

    frame->virt_address = 0;
    frame->flags = 0;
}

bool_t vm_test() {
    uint64_t small_virt_address = vm_find_free_virt_address(g_proc_local.kernel_page_table, 10);
    kassert(is_virt_addr_mapped(small_virt_address) == FALSE);

    vm_map_phys_to_virt(0x0, small_virt_address, 10, VMMAP_FORCE);
    kassert(is_virt_addr_mapped(small_virt_address));

    uint64_t virt_address = vm_find_free_virt_address(g_proc_local.kernel_page_table, (MB_SIZE * 3) / PAGE_BYTE_SIZE);
    kassert(is_virt_addr_mapped(virt_address) == FALSE);
    kassert(virt_address == small_virt_address + (PAGE_BYTE_SIZE * 10));

    vm_map_phys_to_virt(0x0, virt_address, (MB_SIZE * 3) / PAGE_BYTE_SIZE, VMMAP_FORCE);
    kassert(is_virt_addr_mapped(small_virt_address) && is_virt_addr_mapped(virt_address));
    
    vm_unmap(virt_address, g_proc_local.kernel_page_table, (MB_SIZE * 3) / PAGE_BYTE_SIZE);
    kassert(is_virt_addr_mapped(small_virt_address) && is_virt_addr_mapped(virt_address) == FALSE);

    vm_unmap(small_virt_address, g_proc_local.kernel_page_table, 10);
    kassert(is_virt_addr_mapped(small_virt_address) == FALSE && is_virt_addr_mapped(virt_address) == FALSE);

    return TRUE;
}

void vm_setup_paging(PageMapLevel4Entry* pml4) {
    EFER efer = cpu_get_efer();
    efer.noexec_enable = 1;

    cpu_set_efer(efer);
    cpu_set_pml4((PageMapLevel4Entry*)get_phys_address((uint64_t)pml4));
}

void vm_map_kernel(PageMapLevel4Entry* pml4) {
    pml4[0] = g_proc_local.kernel_page_table[0];
    pml4[508] = g_proc_local.kernel_page_table[508];
    pml4[511] = g_proc_local.kernel_page_table[511];
}

void vm_configure_cpu_page_table() {
    PageMapLevel4Entry* pml4 = vm_alloc_page_table();

    // 'g_proc_local' is used as CPU[0] local data
    pml4[0] = g_proc_local.kernel_page_table[0];
    pml4[508] = g_proc_local.kernel_page_table[508];

    vm_map_high_kernel(pml4);
    vm_setup_paging(pml4);

    // Configure processor local data
    const uint32_t cpu_idx = cpu_get_idx();

    // Physical address pointer
    ProcessorLocal* independent_proc_local = _proc_get_local_data_by_idx(cpu_idx);

    kassert(((uint64_t)independent_proc_local % PAGE_BYTE_SIZE) == 0);

    independent_proc_local->idx = cpu_idx;
    independent_proc_local->ioapic_idx = cpu_idx;
    independent_proc_local->current_task = NULL;
    independent_proc_local->kernel_stack = (uint64_t*)(UINT64_MAX - ((uint64_t)initstack * (cpu_idx + 1)));
    independent_proc_local->user_stack = NULL;
    independent_proc_local->kernel_page_table = pml4;

    kassert(independent_proc_local->idx != g_proc_local.idx);

    _vm_map_phys_to_virt((uint64_t)independent_proc_local,
        (uint64_t)&g_proc_local,
        pml4,
        1,
        (VMMAP_WRITE | VMMAP_GLOBAL | VMMAP_WRITE_THROW));

    // Clear TBL cache for page containing 'g_proc_local'
    asm volatile("invlpg (%0)"::"r"(&g_proc_local):"memory");

    kassert(independent_proc_local->idx == g_proc_local.idx);
}