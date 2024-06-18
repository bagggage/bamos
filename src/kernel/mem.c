#include "mem.h"

#include <bootboot.h>

#include "assert.h"
#include "logger.h"
#include "math.h"

#include "cpu/paging.h"
#include "cpu/spinlock.h"

#include "proc/local.h"

#include "vm/buddy_page_alloc.h"
#include "vm/object_mem_alloc.h"
#include "vm/vm.h"

#define PAGE_KB_SIZE (PAGE_BYTE_SIZE / KB_SIZE)

#define UMA_MIN_RANK 3
#define UMA_RANKS_COUNT 13
#define UMA_MAX_RANK (UMA_MIN_RANK + UMA_RANKS_COUNT - 1)

typedef struct UniversalMemoryAllocator {
    ObjectMemoryAllocator* oma_pool[UMA_RANKS_COUNT];
    uint64_t allocated_bytes;

    Spinlock lock;
} UniversalMemoryAllocator;

static UniversalMemoryAllocator uma;

#ifdef KDEBUG
void* malloc(const size_t size) {
    return kmalloc(size);
}

void free(void* mem_block) {
    kfree(mem_block);
}
#endif

void* kmalloc(const size_t size) {
    kassert((size > 0) && (size <= (1 << UMA_MAX_RANK)));

    uint32_t near_rank = log2upper(size);
    if (near_rank < UMA_MIN_RANK) near_rank = UMA_MIN_RANK;

    spin_lock(&uma.lock);

    void* memory_block = oma_alloc(uma.oma_pool[near_rank - UMA_MIN_RANK]);

    if (memory_block != NULL) uma.allocated_bytes += size;

    spin_release(&uma.lock);

    return memory_block;
}

void* kcalloc(const size_t size) {
    uint8_t* memory_block = (uint8_t*)kmalloc(size);

    if (memory_block == NULL) return memory_block;

    memset(memory_block, size, 0);

    return memory_block;
}

void* krealloc(void* memory_block, const size_t size) {
    if (memory_block == NULL) return memory_block;

    spin_lock(&uma.lock);

    uint32_t i = 0;

    for (i = 0; i < UMA_RANKS_COUNT - 1; ++i) {
        if (_oma_is_containing_mem_block(memory_block, uma.oma_pool[i]) == FALSE) continue;
        break;
    }

    spin_release(&uma.lock);

    if (uma.oma_pool[i]->object_size >= size) return memory_block;

    void* new_block = kmalloc(size);

    if (new_block == NULL) return NULL;

    memcpy(memory_block, new_block, uma.oma_pool[i]->object_size);
    kfree(memory_block);
    
    return new_block;
}

void kfree(void* memory_block) {
    if (memory_block == NULL) return;

    spin_lock(&uma.lock);

    for (uint32_t i = 0; i < UMA_RANKS_COUNT; ++i) {
        if (_oma_is_containing_mem_block(memory_block, uma.oma_pool[i]) == FALSE) continue;

        oma_free(memory_block, uma.oma_pool[i]);
        uma.allocated_bytes -= (1 << (i + UMA_MIN_RANK));

        spin_release(&uma.lock);
        return;
    }

    // This branch should be never accessed
    spin_release(&uma.lock);

    kassert(FALSE);
}

uint64_t uma_get_allocated_bytes() {
    return uma.allocated_bytes;
}

static Status init_kernel_uma() {
    uma.allocated_bytes = 0;

    for (uint32_t rank = UMA_MIN_RANK; rank <= UMA_MAX_RANK; ++rank) {
        const uint32_t obj_rank_size = 1 << rank;
    
        ObjectMemoryAllocator* new_oma = oma_new(obj_rank_size);

        if (new_oma == NULL) {
            error_str = "UMA: Can't create new OMA";
            return KERNEL_ERROR;
        }

        uma.oma_pool[rank - UMA_MIN_RANK] = new_oma;
    }

    return KERNEL_OK;
}

extern BOOTBOOT bootboot;

void log_boot_memory_map(const MMapEnt* memory_map, const size_t entries_count) {
    kassert(memory_map != NULL && entries_count > 0);

    size_t used_mem_size = 0;
    size_t free_mem_size = 0;
    size_t invalid_entries = 0;

    for (size_t i = 0; i < entries_count; ++i) {
        const MMapEnt* entry = &memory_map[i];

        if (MMapEnt_Ptr(entry) % PAGE_BYTE_SIZE != 0) {
            invalid_entries++;
            continue;
        }

        const char* type_str = NULL;

        switch (MMapEnt_Type(entry))
        {
        case MMAP_USED: type_str = "USED"; break;
        case MMAP_FREE: type_str = "FREE"; break;
        case MMAP_ACPI: type_str = "ACPI"; break;
        case MMAP_MMIO: type_str = "MMIO"; break;
        default:
            type_str = "INVALID TYPE";
            break;
        }

        if (MMapEnt_IsFree(entry) == FALSE) {
            used_mem_size += MMapEnt_Size(entry);
        }
        else {
            free_mem_size += MMapEnt_Size(entry);
        }

        kernel_msg("Boot memmap entry: %x; size: %x; type: %s\n", MMapEnt_Ptr(entry), MMapEnt_Size(entry), type_str);
    }

    kernel_msg("Used memory: %u KB (%u MB)\n", used_mem_size / KB_SIZE, used_mem_size / MB_SIZE);
    kernel_msg("Free memory: %u KB (%u MB)\n", free_mem_size / KB_SIZE, free_mem_size / MB_SIZE);
    
    if (invalid_entries > 0) {
        kernel_error("Invalid memmap entries: %u\n", (uint32_t)invalid_entries);
    }
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

static bool_t _is_mem_initialized = FALSE;

bool_t is_memory_initialized() {
    return _is_mem_initialized;
}

Status init_memory() {
    MMapEnt* boot_memory_map = (MMapEnt*)&bootboot.mmap;
    size_t map_size = ((uint64_t)bootboot.size - 128) / 16;

    //kernel_warn("Boot memmap: %x (%x)\n", (uint64_t)boot_memory_map, get_phys_address((uint64_t)boot_memory_map));

    VMMemoryMap vm_memory_map = { NULL, 0, 0 };

    if (init_virtual_memory(boot_memory_map, map_size, &vm_memory_map) != KERNEL_OK) return KERNEL_PANIC;

#ifdef KDEBUG
    kernel_warn("VM memmap: %x\n", (uint64_t)vm_memory_map.entries);
    //log_memory_map(&vm_memory_map);
#endif

    if (init_buddy_page_allocator(&vm_memory_map) != KERNEL_OK) return KERNEL_ERROR;
    if (init_vm_allocator() != KERNEL_OK) return KERNEL_ERROR;

#ifdef KDEBUG
    kernel_msg("Testing virtual memory manager...\n");
    vm_test();
#endif

    if (init_kernel_uma() != KERNEL_OK) return KERNEL_ERROR;
    if (init_proc_local() != TRUE) return KERNEL_ERROR;

    _vm_map_proc_local(g_proc_local.kernel_page_table);
    asm volatile("invlpg (%0)"::"r"(&g_proc_local):"memory");

    _is_mem_initialized = TRUE;

    return KERNEL_OK;
}

#define PDE_LOG 0
#define PTE_LOG 1

static void log_memory_page_table_entry(const char* prefix, const size_t idx, const uint64_t base_address, const uint64_t size, const uint8_t level) {
    static const char* const data_size_units_strs[] = { "MB", "KB" };
    static const uint64_t data_size_units[] = { (2 * MB_SIZE), PAGE_BYTE_SIZE };
    //static const uint64_t data_size_multipliers[] = { 2, 4 };

    if (size > 1) {
        kprintf("%s[%u-%u]: %x-%x %u %s\n", prefix, idx - size, idx - 1,
                    base_address,
                    base_address + ((size - 1) * data_size_units[level]),
                    size * ((level + 1) << 1),
                    data_size_units_strs[level]);
    }
    else {
        kprintf("%s[%u]: %x %u %s\n", prefix, idx - 1, base_address, size * ((level + 1) << 1), data_size_units_strs[level]);
    }
}

void log_memory_page_tables(PageMapLevel4Entry* pml4) {
    kassert(pml4 != NULL);

    static const char* const pde_prefix = "|---|---PDE ";
    static const char* const pte_prefix = "|---|---|---PTE ";

    for (size_t i = 0; i < PAGE_TABLE_MAX_SIZE; ++i) {
        if (pml4[i].present == FALSE) continue;

        PageDirPtrEntry* pdpe = (PageDirPtrEntry*)((uint64_t)pml4[i].page_ppn << 12);
        kprintf("PML4E [%u]: %x\n", i, pdpe);

        for (size_t j = 0; j < PAGE_TABLE_MAX_SIZE; ++j) {
            if (pdpe[j].present == FALSE) continue;

            PageDirEntry* pde = (PageDirEntry*)((uint64_t)pdpe[j].page_ppn << 12);
            kprintf("|---PDPE [%u]: %x %s\n", j, (uint64_t)pde, pdpe[j].size ? "1 GB" : "");

            uint64_t base_address = UINT64_MAX;
            uint64_t size = 1;

            if (pdpe[j].size == 1) continue;

            for (size_t g = 0; g < PAGE_TABLE_MAX_SIZE; ++g) {
                if (pde[g].present == FALSE) {
                    if (base_address != UINT64_MAX) log_memory_page_table_entry(pde_prefix, g, base_address, size, PDE_LOG);

                    base_address = UINT64_MAX;
                    continue;
                }

                const uint64_t address = (uint64_t)((uint64_t)pde[g].page_ppn << 12);
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

                kprintf("%s[%u]: %x\n", pde_prefix, g, (uint64_t)pte);

                for (size_t h = 0; h < PAGE_TABLE_MAX_SIZE; ++h) {
                    if (pte[h].present == FALSE) { 
                        if (base_address != UINT64_MAX) log_memory_page_table_entry(pte_prefix, h, base_address, size, PTE_LOG);

                        base_address = UINT64_MAX;
                        continue;
                    }

                    const uint64_t _address = (uint64_t)((uint64_t)pte[h].page_ppn << 12);

                    //kernel_warn("|---|---|---Page table entry[%u]: %x 4 KB\n", h, address);
                    //continue;

                    if (base_address == UINT64_MAX) {
                        base_address = _address;
                        size = 1;
                        continue;
                    }
                    if (base_address == _address - (size * PAGE_BYTE_SIZE)) {
                        ++size;
                    }
                    else {
                        log_memory_page_table_entry(pte_prefix, h, base_address, size, PTE_LOG);
                        size = 1;
                        base_address = _address;
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

static inline bool_t is_page_table_entry_valid(const PageXEntry* pte) {
    return *(const uint64_t*)pte != 0;
}

VMPxE _get_pxe_of_virt_addr(const PageMapLevel4Entry* pml4, const uint64_t address) {
    VMPxE result;

    result.entry = 0;
    result.level = 0;

    if (is_virt_address_valid(address) == FALSE) return result;

    const VirtualAddress* virtual_addr = (VirtualAddress*)&address;
    const PageMapLevel4Entry* plm4e = pml4 + virtual_addr->p4_index;

    if (is_page_table_entry_valid(plm4e) == FALSE) return (VMPxE){ 0, 0 };

    const PageDirPtrEntry* pdpe = (const PageDirPtrEntry*)((uint64_t)plm4e->page_ppn << 12) + virtual_addr->p3_index;
    result.entry = (uint64_t)pdpe;
    result.level++;

    if (is_page_table_entry_valid(pdpe) == FALSE) return (VMPxE){ 0, 0 };
    if (pdpe->size == 1) return result;

    const PageDirEntry* pde = (const PageDirEntry*)((uint64_t)pdpe->page_ppn << 12) + virtual_addr->p2_index;
    result.entry = (uint64_t)pde;
    result.level++;

    if (is_page_table_entry_valid(pde) == FALSE) return (VMPxE){ 0, 0 };
    if (pde->size == 1) return result;

    const PageTableEntry* pte = (const PageTableEntry*)((uint64_t)pde->page_ppn << 12) + virtual_addr->p1_index;
    result.entry = (uint64_t)pte;
    result.level++;

    return (is_page_table_entry_valid((const PageXEntry*)pte) == FALSE ? (VMPxE){ 0, 0 } : result);
}

VMPxE get_pxe_of_virt_addr(const uint64_t address) {
    return _get_pxe_of_virt_addr(cpu_get_current_pml4(), address);
}

bool_t is_virt_addr_mapped_userspace(const PageMapLevel4Entry* pml4, const uint64_t address) {
    if (is_virt_address_valid(address) == FALSE ||
        address < USER_SPACE_ADDR_BEGIN ||
        address >= KERNEL_HEAP_VIRT_ADDRESS) {
        return FALSE;
    }

    return _get_pxe_of_virt_addr(pml4, address).entry != 0;
}

bool_t is_virt_addr_mapped(const uint64_t address) {
    return get_pxe_of_virt_addr(address).entry != 0;
}

bool_t is_virt_addr_range_mapped(const uint64_t address, const uint32_t pages_count) {
    for (uint32_t i = 0; i < pages_count; ++i) {
        if (is_virt_addr_mapped(address + ((uint64_t)i * PAGE_BYTE_SIZE)) == FALSE) {
            return FALSE;
        }
    }

    return TRUE;
}

uint64_t _get_phys_address(const PageMapLevel4Entry* pml4, const uint64_t virt_addr) {
    VMPxE pxe = _get_pxe_of_virt_addr(pml4, virt_addr);

    if (pxe.entry == 0) return INVALID_ADDRESS;

    pxe.level--;

    return ((uint64_t)((uint64_t)((PageXEntry*)(uint64_t)pxe.entry)->page_ppn) * PAGE_BYTE_SIZE) +
            (virt_addr & (0x3FFFFFFF >> (9 * (uint64_t)pxe.level)));
}

uint64_t get_phys_address(const uint64_t virt_addr) {
    return _get_phys_address(cpu_get_current_pml4(), virt_addr);
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

int memcmp(const void* lhs, const void *rhs, size_t size) {
    kassert(lhs != NULL && rhs != NULL);

    const uint8_t* l = lhs;
    const uint8_t* r = rhs;

    for (; size && *l == *r; size--, l++, r++);

    return (size != 0 ? (*l - *r) : 0);
}

int strcmp(const char* s1, const char* s2) {
    while (*s1 && (*s1 == *s2)) {
        s1++;
        s2++;
    }

    return *(const unsigned char*)s1 - *(const unsigned char*)s2;
}

int strcpy(char *dst, const char *src) {
    int i = 0;
    while ((*dst++ = *src++) != 0)
        i++;
    return i;
}

size_t strlen(const char* str) {
    const char* s;

    for (s = str; *s; ++s);

    return (s - str);
}

static char* strtok_r(char *s, const char *delim, char **last) {
	char *spanp;
	int c, sc;
	char *tok;
	if (s == NULL && (s = *last) == NULL)
		return (NULL);
	/*
	 * Skip (span) leading delimiters (s += strspn(s, delim), sort of).
	 */
cont:
	c = *s++;
	for (spanp = (char *)delim; (sc = *spanp++) != 0;) {
		if (c == sc)
			goto cont;
	}
	if (c == 0) {		/* no non-delimiter characters */
		*last = NULL;
		return (NULL);
	}
	tok = s - 1;
	/*
	 * Scan token (scan for delimiters: s += strcspn(s, delim), sort of).
	 * Note that delim must have one NUL; we stop if we see that, too.
	 */
	for (;;) {
		c = *s++;
		spanp = (char *)delim;
		do {
			if ((sc = *spanp++) == c) {
				if (c == 0)
					s = NULL;
				else
					s[-1] = 0;
				*last = s;
				return (tok);
			}
		} while (sc != 0);
	}
	/* NOTREACHED */
}

char* strtok(char *s, const char *delim) {
	static char *last;
	return strtok_r(s, delim, &last);
}