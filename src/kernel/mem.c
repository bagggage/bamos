#include "mem.h"

#include <bootboot.h>

#include "logger.h"

#include "cpu/paging.h"

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

    return NULL;
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
}
#endif

extern BOOTBOOT bootboot;

Status init_memory() {
    kernel_msg("Memory map:\n");

    MMapEnt* mem_map = (MMapEnt*)&bootboot.mmap.ptr;
    size_t used_mem_size_in_kb = 0;
    size_t mem_size_in_kb = 0;

    for (size_t i = 0; i < (bootboot.size - (sizeof(bootboot))) / sizeof(MMapEnt); ++i) {
        const char* type_str = NULL;

        switch (MMapEnt_Type(mem_map + i))
        {
        case MMAP_USED: type_str = "USED"; break;
        case MMAP_FREE: type_str = "FREE"; break;
        case MMAP_ACPI: type_str = "ACPI"; break;
        case MMAP_MMIO: type_str = "MMIO"; break;
        default:
            type_str = "INVALID TYPE";
            break;
        }

        if (MMapEnt_Type(mem_map + i) != MMAP_FREE) used_mem_size_in_kb += mem_map[i].size;

        mem_size_in_kb += mem_map[i].size;

        kernel_msg("Entry - ptr: %x; size: %u; type: %s\n", mem_map[i].ptr, mem_map[i].size, type_str);
    }

    kernel_msg("Used memmory: %u KB (%u MB)\n", used_mem_size_in_kb / 1024, used_mem_size_in_kb / (1024*1024));
    kernel_msg("Memory size: %u KB (%u MB)\n", mem_size_in_kb / 1024, mem_size_in_kb / (1024*1024));

    return KERNEL_OK;
}

void log_memory_page_tables() {
    PageMapLevel4Entry* pml4 = cpu_get_current_pml4();

    kernel_msg("PLM4: %x\n", pml4);

    for (size_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        if (pml4[i].present == FALSE) continue;

        PageDirPtrEntry* pdpe = (PageDirPtrEntry*)(uint64_t)(pml4[i].page_ppn << 12);
        kernel_msg("Page map level 4 entry[%u]: %x\n", i, pdpe);

        for (size_t j = 0; j < PAGE_TABLE_MAX_SIZE; ++j) {
            if (pdpe[j].present == FALSE) continue;

            PageDirEntry* pde = (PageDirEntry*)(uint64_t)(pdpe[j].page_ppn << 12);
            kernel_msg("|---Page directory ptr entry[%u]: %x %s\n", j, pde, pdpe[i].size ? "1 GB" : "");

            for (size_t g = 0; g < PAGE_TABLE_MAX_SIZE; ++g) {
                if (pde[g].present == FALSE) continue;

                PageTableEntry* pte = (PageTableEntry*)(uint64_t)(pde[g].page_ppn << 12);
                kernel_msg("|---|---Page directory entry[%u]: %x\n", g, pte);
            }
        }
    }
}

static inline bool_t is_virt_addr_valid(uint64_t address) {
    VirtualAddress virtual_addr = *(VirtualAddress*)&address;

    return (virtual_addr.sign_extended == 0 || virtual_addr.sign_extended == 0xFFFF);
}

static inline bool_t is_page_table_entry_valid(PageXEntry* pte) {
    return *(uint64_t*)pte != 0;
}

static inline void log_page_table_entry(PageXEntry* pte) {
    kernel_msg("PTE %x:\n", pte);
    kernel_msg("|---Present: %u\n", (uint32_t)pte->present);
    kernel_msg("|---Page base: %u\n", (uint32_t)pte->page_ppn);
}

PageTableEntry* get_pte_of_virt_addr(uint64_t address) {
    if (is_virt_addr_valid(address) == FALSE) return NULL;

    VirtualAddress virtual_addr = *(VirtualAddress*)&address;
    PageMapLevel4Entry* plm4e = cpu_get_current_pml4() + virtual_addr.p4_index;

    if (is_page_table_entry_valid(plm4e) == FALSE) return NULL;

    PageDirPtrEntry* pdpe = (PageDirPtrEntry*)(uint64_t)(plm4e->page_ppn << 12) + virtual_addr.p3_index;

    if (is_page_table_entry_valid(pdpe) == FALSE) return NULL;

    PageDirEntry* pde = (PageDirEntry*)(uint64_t)(pdpe->page_ppn << 12) + virtual_addr.p2_index;

    if (is_page_table_entry_valid(pde) == FALSE) return NULL;

    PageTableEntry* pte = (PageTableEntry*)(uint64_t)(pde->page_ppn << 12) + virtual_addr.p1_index;

    return (is_page_table_entry_valid((PageXEntry*)pte) == FALSE ? NULL : pte);
}

bool_t is_virt_addr_mapped(uint64_t address) {
    return get_pte_of_virt_addr(address) != NULL;
}

uint64_t get_phys_address(uint64_t virt_addr) {
    VirtualAddress virtual_addr = *(VirtualAddress*)&virt_addr;
    PageTableEntry* pte = get_pte_of_virt_addr(virt_addr);

    if (pte == NULL) return INVALID_ADDRESS;

    return (pte->page_ppn << 12) + virtual_addr.offset;
}

void memcpy(const void* src, void* dst, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        ((uint8_t*)dst)[i] = ((const uint8_t*)src)[i];
    }
}

void memset(void* dst, size_t size, uint8_t value) {
    for (size_t i = 0; i < size; ++i) {
        ((uint8_t*)dst)[i] = value;
    }
}