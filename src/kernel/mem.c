#include "mem.h"

#include <bootboot.h>

#include "cpu/paging.h"

#include "efi-st.h"

#include "logger.h"

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
}
#endif

extern BOOTBOOT bootboot;

static inline void log_memory_map(MMapEnt* mem_map, size_t size) {
    size_t used_mem_size = 0;
    size_t mem_size = 0;

    for (size_t i = 0; i < size; ++i) {
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

        if (MMapEnt_IsFree(mem_map + i) == FALSE) used_mem_size += MMapEnt_Size(mem_map + i);

        mem_size = MMapEnt_Ptr(mem_map + i) + MMapEnt_Size(mem_map + i);

        kernel_msg("Entry - ptr: %x; size: %x; type: %s\n", MMapEnt_Ptr(mem_map + i), MMapEnt_Size(mem_map + i), type_str);
    }

    kernel_msg("Used memmory: %u KB (%u MB)\n", used_mem_size / 1024, used_mem_size / (1024*1024));
    kernel_msg("Memory size: %u KB (%u MB)\n", mem_size / 1024, mem_size / (1024*1024));
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
    kernel_msg("Memory map:\n");

    MMapEnt* mem_map = (MMapEnt*)&bootboot.mmap.ptr;
    size_t map_size = (bootboot.size - (sizeof(bootboot))) / sizeof(MMapEnt);

    kernel_msg("Memory map entries count: %u\n", map_size);
    log_memory_map(mem_map, map_size);

    if (init_virtual_memory(mem_map, map_size) != KERNEL_OK) return KERNEL_PANIC;

    kernel_msg("Kernel start: %x; end: %x; size: %x\n",
                &kernel_elf_start,
                &kernel_elf_end,
                (uint64_t)&kernel_elf_end - (uint64_t)&kernel_elf_start);

    kernel_msg("Initrd %x\n", bootboot.initrd_ptr);

    return KERNEL_OK;

    size_t count_of_mapped_memory = 0;
    PageMapLevel4Entry* pml4 = cpu_get_current_pml4();

    for (uint16_t i = 0; i < 512; ++i) {
        PageDirEntry* pde = (PageDirEntry*)(pml4[i].page_ppn << 12);
        if (pml4[i].present == 0) continue;

        kernel_msg("PDPE [%u]: %x:%x\n", (uint32_t)i, (uint64_t)pde, get_phys_address((uint64_t)pde));

        for (uint16_t j = 0; j < 512; ++j) {
            PageDirPtrEntry* pdpe = (PageDirPtrEntry*)(pde[j].page_ppn << 12);
            if (pde[j].present == 0) continue;
            if (pde[j].size == 1) {
                count_of_mapped_memory += 1024 * 1024 * 1024;
                continue;
            }

            for (uint16_t g = 0; g < 512; ++g) {
                PageTableEntry* pte = (PageTableEntry*)(pdpe[g].page_ppn << 12);
                if (pdpe[g].present == 0) continue;
                if (pdpe[g].size == 1) {
                    count_of_mapped_memory += 2048 * 1024;
                    continue;
                }

                for (uint16_t h = 0; h < 512; ++h) {
                    if (pte[h].present == 0) continue;

                    count_of_mapped_memory += 4096;
                }
            }
        }
    }

    kernel_msg("Count of mapped pages: %x\n", count_of_mapped_memory);
    //kernel_msg("Random kernel virt/phys address: %x:%x\n", (uint64_t)&init_memory, get_phys_address(&init_memory));
    //kernel_msg("Bootboot structure phys address: %x\n", get_phys_address(&bootboot));
    //kernel_msg("MMIO start phys address: %x\n", get_phys_address(bootboot.arch.x86_64.acpi_ptr));

    return KERNEL_OK;
}

void log_memory_page_tables() {
    PageMapLevel4Entry* pml4 = cpu_get_current_pml4();

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
    VirtualAddress* virtual_addr = (VirtualAddress*)&address;

    return (virtual_addr->sign_extended == 0 || virtual_addr->sign_extended == 0xFFFF);
}

static inline bool_t is_page_table_entry_valid(PageXEntry* pte) {
    return *(uint64_t*)pte != 0;
}

static inline void log_page_table_entry(PageXEntry* pte) {
    kernel_msg("PTE %x:\n", pte);
    kernel_msg("|---Present: %u\n", (uint32_t)pte->present);
    kernel_msg("|---Page base: %u\n", (uint32_t)pte->page_ppn);
}

typedef struct PxE {
    uint64_t entry : 62;
    uint64_t level : 2;
} ATTR_PACKED PxE;

PxE get_pxe_of_virt_addr(uint64_t address) {
    PxE result;

    result.entry = 0;
    result.level = 0;

    if (is_virt_addr_valid(address) == FALSE) return result;

    VirtualAddress* virtual_addr = (VirtualAddress*)&address;
    PageMapLevel4Entry* plm4e = cpu_get_current_pml4() + virtual_addr->p4_index;

    if (is_page_table_entry_valid(plm4e) == FALSE) return (PxE){ 0, 0 };

    PageDirPtrEntry* pdpe = (PageDirPtrEntry*)(uint64_t)(plm4e->page_ppn << 12) + virtual_addr->p3_index;
    result.entry = (uint64_t)pdpe;
    result.level++;

    if (is_page_table_entry_valid(pdpe) == FALSE) return (PxE){ 0, 0 };
    if (pdpe->size == 1) return result;

    PageDirEntry* pde = (PageDirEntry*)(uint64_t)(pdpe->page_ppn << 12) + virtual_addr->p2_index;
    result.entry = (uint64_t)pde;
    result.level++;

    if (is_page_table_entry_valid(pde) == FALSE) return (PxE){ 0, 0 };
    if (pde->size == 1) return result;

    PageTableEntry* pte = (PageTableEntry*)(uint64_t)(pde->page_ppn << 12) + virtual_addr->p1_index;
    result.entry = (uint64_t)pte;
    result.level++;

    return (is_page_table_entry_valid((PageXEntry*)pte) == FALSE ? (PxE){ 0, 0 } : result);
}

bool_t is_virt_addr_mapped(uint64_t address) {
    return get_pxe_of_virt_addr(address).entry != 0;
}

uint64_t get_phys_address(uint64_t virt_addr) {
    PxE pxe = get_pxe_of_virt_addr(virt_addr);

    if (pxe.entry == 0) return INVALID_ADDRESS;

    pxe.level--;

    return (((PageXEntry*)pxe.entry)->page_ppn << 12) + (virt_addr & (0x3FFFFFFF >> (9 * pxe.level)));
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