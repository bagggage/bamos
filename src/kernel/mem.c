#include "mem.h"

#include <bootboot.h>

#include "assert.h"
#include "cpu/paging.h"

#include "logger.h"

#include "vm/buddy_page_alloc.h"
#include "vm/vm.h"

#define PAGE_KB_SIZE (PAGE_BYTE_SIZE / KB_SIZE)

#ifdef MEM_RAW_PATCH
typedef struct MemBlock {
    void* ptr;
    uint64_t size;
} MemBlock;

#define MAX_BLOCKS 1024

MemBlock allocated_blocks[MAX_BLOCKS] = { 0 }; 
size_t allocated_blocks_count = 0;

uint8_t mem_buffer[MB_SIZE] = { 0 };
uint8_t* buffer_ptr = mem_buffer;

MemBlock* get_next_allocated_block(size_t i) {
    MemBlock* last_block = NULL;

    ++i;

    while (i < MAX_BLOCKS && allocated_blocks[i].size == 0) {
        last_block = &allocated_blocks[i];
        ++i;
    }

    return last_block;
}

void* kmalloc(size_t size) {
    if (allocated_blocks_count >= MAX_BLOCKS || size == 0) return NULL;

    size_t allocated_i = 0;

    for (size_t i = 0; i < MAX_BLOCKS; ++i) {
        if (allocated_blocks[i].size == 0) {
            bool_t is_last = FALSE;

            if (allocated_blocks[i].ptr == NULL) {
                is_last = TRUE;
            }
            else {
                MemBlock* next_block = get_next_allocated_block(i);

                if (next_block->ptr == NULL) {
                    is_last = TRUE;
                }
                else {
                    size_t max_block_size = next_block->ptr - allocated_blocks[i].ptr;

                    if (max_block_size >= size) {
                        next_block->ptr = allocated_blocks[i].ptr + size;
                        
                        allocated_blocks[i].size = size;
                        ++allocated_blocks_count;

                        return allocated_blocks[i].ptr;
                    }

                    continue;
                }
            }

            if (is_last) {
                if ((buffer_ptr - mem_buffer) + size >= sizeof(mem_buffer)) return NULL;

                allocated_blocks[i].ptr = buffer_ptr;
                allocated_blocks[i].size = size;

                buffer_ptr += size;
                ++allocated_blocks_count;

                return allocated_blocks[i].ptr;
            }
        }
        else {
            ++allocated_i;
        }
    }

    return NULL;
}

MemBlock* find_block(void* allocated_mem) {
    for (size_t i = 0; i < MAX_BLOCKS; ++i) {
        if (allocated_blocks[i].ptr == allocated_mem) return &allocated_blocks[i];
    }

    return NULL;
}

void kfree(void* allocated_mem) {
    if (allocated_mem == NULL) return;

    MemBlock* block = find_block(allocated_mem);

    if (block == NULL) return;

    block->size = 0;
    --allocated_blocks_count;
}
#else
void* kmalloc(size_t size) {
    return NULL;
}

void kfree(void* allocated_mem) {
    kassert(allocated_mem != NULL);
}
#endif

extern BOOTBOOT bootboot;

void log_boot_memory_map(const MMapEnt* memory_map, const size_t entries_count) {
    kassert(memory_map != NULL);

    size_t used_mem_size = 0;
    size_t mem_size = 0;

    for (size_t i = 0; i < entries_count; ++i) {
        const char* type_str = NULL;

        switch (MMapEnt_Type(memory_map + i))
        {
        case MMAP_USED: type_str = "USED"; break;
        case MMAP_FREE: type_str = "FREE"; break;
        case MMAP_ACPI: type_str = "ACPI"; break;
        case MMAP_MMIO: type_str = "MMIO"; break;
        default:
            type_str = "INVALID TYPE";
            break;
        }

        if (MMapEnt_IsFree(memory_map + i) == FALSE) used_mem_size += MMapEnt_Size(memory_map + i);

        mem_size = MMapEnt_Ptr(memory_map + i) + MMapEnt_Size(memory_map + i);

        kernel_msg("Entry - ptr: %x; size: %x; type: %s\n", MMapEnt_Ptr(memory_map + i), MMapEnt_Size(memory_map + i), type_str);
    }

    kernel_msg("Used memmory: %u KB (%u MB)\n", used_mem_size / KB_SIZE, used_mem_size / MB_SIZE);
    kernel_msg("Memory size: %u KB (%u MB)\n", mem_size / KB_SIZE, mem_size / MB_SIZE);
}

void log_pages_count() {
    size_t current_block_number = 0;
    size_t pages_count = 0;
    uint64_t previous_phys_address = 0;

    for (uint64_t current_page_virt_address = 0x0;
        current_page_virt_address <= MAX_PAGE_ADDRESS;
        current_page_virt_address += PAGE_BYTE_SIZE) {
        uint64_t current_phys_address = get_phys_address(current_page_virt_address);
        
        if (current_phys_address == INVALID_ADDRESS) {
            if (pages_count != 0) {
                kernel_msg("Block [%u]: %x; pages count: %u\n", 
                            current_block_number,
                            current_page_virt_address - (PAGE_BYTE_SIZE * (pages_count + 1)),
                            pages_count + 1);

                ++current_block_number;
            }

            pages_count = 0;
            previous_phys_address = 0;
            continue;
        }

        if (previous_phys_address == 0 || current_phys_address == previous_phys_address + PAGE_BYTE_SIZE) {
            ++pages_count;
            previous_phys_address = current_phys_address;
        } else {
            //if (pages_count > 1) {
                kernel_msg("Block [%u]: %x; pages count: %u\n",
                            current_block_number,
                            current_page_virt_address - (PAGE_BYTE_SIZE * (pages_count + 1)),
                            pages_count + 1);
            //}

            ++current_block_number;
            pages_count = 0;
            previous_phys_address = 0;
        }
    }

    if (pages_count != 0) {
        kernel_msg("Pages count: %u\n", pages_count);
    }
}

extern uint64_t kernel_elf_start;
extern uint64_t kernel_elf_end;

Status init_memory() {
    MMapEnt* boot_memory_map = (MMapEnt*)&bootboot.mmap.ptr;
    size_t map_size = (bootboot.size - (sizeof(bootboot))) / sizeof(MMapEnt);

    VMMemoryMap vm_memory_map = { NULL, 0 };

    if (init_virtual_memory(boot_memory_map, map_size, &vm_memory_map) != KERNEL_OK) return KERNEL_PANIC;

#ifdef KDEBUG
    log_memory_map(&vm_memory_map);
#endif

    if (init_buddy_page_allocator(&vm_memory_map) != KERNEL_OK) {
        error_str = "Failed to initialize buddy page allocator";
        return KERNEL_ERROR;
    }

    return KERNEL_OK;
}

#define PDE_LOG 0
#define PTE_LOG 1

static void log_memory_page_table_entry(const char* prefix, const size_t idx, const uint64_t base_address, const uint64_t size, const uint8_t level) {
    static const char* const data_size_units_strs[] = { "MB", "KB" };
    static const uint64_t data_size_units[] = { (2 * MB_SIZE), PAGE_BYTE_SIZE };
    //static const uint64_t data_size_multipliers[] = { 2, 4 };

    if (size > 1) {
        kernel_warn("%s[%u-%u]: %x-%x %u %s\n", prefix, idx - size, idx - 1,
                    base_address,
                    base_address + ((size - 1) * data_size_units[level]),
                    size * ((level + 1) << 1),
                    data_size_units_strs[level]);
    }
    else {
        kernel_warn("%s[%u]: %x %u %s\n", prefix, idx - 1, base_address, size * ((level + 1) << 1), data_size_units_strs[level]);
    }
}

void log_memory_page_tables(PageMapLevel4Entry* pml4) {
    kassert(pml4 != NULL);

    static const char* const pde_prefix = "|---|---PDE ";
    static const char* const pte_prefix = "|---|---|---PTE ";

    for (size_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        if (pml4[i].present == FALSE) continue;

        PageDirPtrEntry* pdpe = (PageDirPtrEntry*)((uint64_t)pml4[i].page_ppn << 12);
        kernel_warn("PML4E [%u]: %x\n", i, pdpe);

        for (size_t j = 0; j < PAGE_TABLE_MAX_SIZE; ++j) {
            if (pdpe[j].present == FALSE) continue;

            PageDirEntry* pde = (PageDirEntry*)((uint64_t)pdpe[j].page_ppn << 12);
            kernel_warn("|---PDPE [%u]: %x %s\n", j, (uint64_t)pde, pdpe[j].size ? "1 GB" : "");

            uint64_t base_address = UINT64_MAX;
            uint64_t size = 1;

            if (pdpe[j].size == 1) continue;

            for (size_t g = 0; g < PAGE_TABLE_MAX_SIZE; ++g) {
                if (pde[g].present == FALSE) {
                    if (base_address != UINT64_MAX) log_memory_page_table_entry(pde_prefix, g, base_address, size, PDE_LOG);

                    base_address = UINT64_MAX;
                    continue;
                }

                uint64_t address = (uint64_t)((uint64_t)pde[g].page_ppn << 12);
                PageTableEntry* pte = (PageTableEntry*)address;

                if (pde[g].size == 1) { 
                    if (base_address == UINT64_MAX) {
                        base_address = address;
                        size = 1;
                        continue;
                    }
                    if (base_address == address - (size * (2 * MB_SIZE))) {
                        ++size;
                    }
                    else {
                        log_memory_page_table_entry(pde_prefix, g, base_address, size, PDE_LOG);
                        size = 1;
                        base_address = address;
                    }

                    continue;
                }
                else if (base_address != UINT64_MAX) {
                    log_memory_page_table_entry(pde_prefix, g, base_address, size, PDE_LOG);
                }

                base_address = UINT64_MAX;
                size = 1;

                kernel_warn("%s[%u]: %x\n", pde_prefix, g, (uint64_t)pte);

                for (size_t h = 0; h < PAGE_TABLE_MAX_SIZE; ++h) {
                    if (pte[h].present == FALSE) { 
                        if (base_address != UINT64_MAX) log_memory_page_table_entry(pte_prefix, h, base_address, size, PTE_LOG);

                        base_address = UINT64_MAX;
                        continue;
                    }

                    uint64_t address = (uint64_t)((uint64_t)pte[h].page_ppn << 12);

                    //kernel_warn("|---|---|---Page table entry[%u]: %x 4 KB\n", h, address);
                    //continue;

                    if (base_address == UINT64_MAX) {
                        base_address = address;
                        size = 1;
                        continue;
                    }
                    if (base_address == address - (size * PAGE_BYTE_SIZE)) {
                        ++size;
                    }
                    else {
                        log_memory_page_table_entry(pte_prefix, h, base_address, size, PTE_LOG);
                        size = 1;
                        base_address = address;
                    }
                }

                if (base_address != UINT64_MAX) {
                    log_memory_page_table_entry(pte_prefix,
                                                PAGE_TABLE_MAX_SIZE,
                                                base_address, size, PTE_LOG);

                    base_address = UINT64_MAX;
                }
            }

            if (base_address != UINT64_MAX) {
                log_memory_page_table_entry(pde_prefix,
                                            PAGE_TABLE_MAX_SIZE,
                                            base_address, size, PDE_LOG);
            }
        }
    }
}

static inline bool_t is_page_table_entry_valid(PageXEntry* pte) {
    return *(uint64_t*)pte != 0;
}

VMPxE get_pxe_of_virt_addr(const uint64_t address) {
    VMPxE result;

    result.entry = 0;
    result.level = 0;

    if (is_virt_address_valid(address) == FALSE) return result;

    VirtualAddress* virtual_addr = (VirtualAddress*)&address;
    PageMapLevel4Entry* plm4e = cpu_get_current_pml4() + virtual_addr->p4_index;

    if (is_page_table_entry_valid(plm4e) == FALSE) return (VMPxE){ 0, 0 };

    PageDirPtrEntry* pdpe = (PageDirPtrEntry*)((uint64_t)plm4e->page_ppn << 12) + virtual_addr->p3_index;
    result.entry = (uint64_t)pdpe;
    result.level++;

    if (is_page_table_entry_valid(pdpe) == FALSE) return (VMPxE){ 0, 0 };
    if (pdpe->size == 1) return result;

    PageDirEntry* pde = (PageDirEntry*)((uint64_t)pdpe->page_ppn << 12) + virtual_addr->p2_index;
    result.entry = (uint64_t)pde;
    result.level++;

    if (is_page_table_entry_valid(pde) == FALSE) return (VMPxE){ 0, 0 };
    if (pde->size == 1) return result;

    PageTableEntry* pte = (PageTableEntry*)((uint64_t)pde->page_ppn << 12) + virtual_addr->p1_index;
    result.entry = (uint64_t)pte;
    result.level++;

    return (is_page_table_entry_valid((PageXEntry*)pte) == FALSE ? (VMPxE){ 0, 0 } : result);
}

bool_t is_virt_addr_mapped(const uint64_t address) {
    return get_pxe_of_virt_addr(address).entry != 0;
}

uint64_t get_phys_address(const uint64_t virt_addr) {
    VMPxE pxe = get_pxe_of_virt_addr(virt_addr);

    if (pxe.entry == 0) return INVALID_ADDRESS;

    pxe.level--;

    return ((uint64_t)((uint64_t)((PageXEntry*)(uint64_t)pxe.entry)->page_ppn) << 12) + (virt_addr & (0x3FFFFFFF >> (9 * (uint64_t)pxe.level)));
}

void memcpy(const void* src, void* dst, size_t size) {
    kassert(src != NULL && dst != NULL);

    for (size_t i = 0; i < size; ++i) {
        ((uint8_t*)dst)[i] = ((const uint8_t*)src)[i];
    }
}

void memset(void* dst, size_t size, uint8_t value) {
    kassert(dst != NULL);

    for (size_t i = 0; i < size; ++i) {
        ((uint8_t*)dst)[i] = value;
    }
}