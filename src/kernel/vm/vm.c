#include "vm.h"

#include <bootboot.h>

#include "cpu/paging.h"
#include "cpu/regs.h"

#include "logger.h"
#include "mem.h"

extern BOOTBOOT bootboot;

typedef struct BamOsMagic {
    const char signature[8];
    bool_t test_flag;
} ATTR_PACKED BamOsMagic;

// Must be non-static and aligned to page size!
ATTR_ALIGN(PAGE_BYTE_SIZE)
BamOsMagic global_bamos_magic = {
    { 'B',0xF0,'A',0x0E,'M',0xD0,'O','S' },
    FALSE
};

RawMemoryBlock vm_kernel_stack;
RawMemoryBlock vm_kernel_segments;

ATTR_ALIGN(PAGE_BYTE_SIZE)
PageMapLevel4Entry vm_pml4[PAGE_TABLE_MAX_SIZE];

extern uint64_t kernel_elf_start;
extern uint64_t kernel_elf_end;

// Linker setted stack size
extern uint64_t initstack[];

static void setup_pml4() {
}

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

static const MMapEnt* find_first_suitable_mmap_block(const MMapEnt* memory_map, const size_t entries_count, const size_t pages_count) {
    for (size_t i = 0; i < entries_count; ++i) {
        const MMapEnt* entry = memory_map + i;

        if (MMapEnt_Type(entry) != MMAP_FREE || MMapEnt_Size(entry) < pages_count * PAGE_BYTE_SIZE) continue;

        return entry;
    }

    return NULL;
}

static BamOsMagic* find_bamos_magic_in_memory() {
    BamOsMagic* iterator = 0x1000;

    while ((uint64_t)iterator < MAX_PHYS_ADDRESS) {
        if (*((uint64_t*)iterator) == *((uint64_t*)&global_bamos_magic)) {
            kernel_msg("Found BamOS magic at: %x\n", (uint64_t)iterator);

            // Testing
            global_bamos_magic.test_flag = FALSE;
            if (iterator->test_flag != FALSE) continue;

            iterator->test_flag = TRUE;
            if (global_bamos_magic.test_flag == TRUE) return iterator;
        }

        iterator = (BamOsMagic*)((uint64_t)iterator + PAGE_BYTE_SIZE);
    }

    return NULL;
}

Status init_virtual_memory(const MMapEnt* bootboot_mem_map, const size_t entries_count) {
    const size_t kernel_sections_size = (uint64_t)&kernel_elf_end - (uint64_t)&kernel_elf_start;
    const size_t kernel_pages_count = (kernel_sections_size / PAGE_BYTE_SIZE) + (kernel_sections_size % PAGE_BYTE_SIZE == 0 ? 0 : 1);

    const size_t kernel_2m_pages_count = kernel_pages_count / (2 * MB_SIZE / PAGE_BYTE_SIZE);
    const size_t kernel_4kb_pages_count = kernel_pages_count % (2 * MB_SIZE / PAGE_BYTE_SIZE);

    BamOsMagic* magic = find_bamos_magic_in_memory();

    if (magic == NULL) {
        error_str = "BamOS magic not found or not available";
        return KERNEL_ERROR;
    }

    const size_t kernel_virt_to_phys_offset = (uint64_t)magic - (uint64_t)&global_bamos_magic;

    const uint64_t kernel_phys_start = (uint64_t)&kernel_elf_start + kernel_virt_to_phys_offset;
    const uint64_t kernel_phys_end = (uint64_t)&kernel_elf_end + kernel_virt_to_phys_offset;

    kernel_msg("Kernel virtual address space offset: %x\n", kernel_virt_to_phys_offset);
    kernel_msg("Kernel phys start: %x\n", kernel_phys_start);
    kernel_msg("Kernel phys end: %x\n", kernel_phys_end);

    // Replace and map stack
    const MMapEnt* stack_mmap_entry = find_first_suitable_mmap_block(bootboot_mem_map, entries_count, KERNEL_STACK_SIZE / PAGE_BYTE_SIZE);

    if (stack_mmap_entry == NULL) {
        error_str = "Not found suitable memory block for replacing stack";
        return KERNEL_ERROR;
    }

    vm_kernel_stack.phys_address = MMapEnt_Ptr(stack_mmap_entry);
    vm_kernel_stack.virt_address = (UINT64_MAX - KERNEL_STACK_SIZE) + 1;
    vm_kernel_stack.size = KERNEL_STACK_SIZE;

    kernel_msg("Stack memory block: %x\n", vm_kernel_stack.phys_address);
    kernel_msg("rsp: %x; initstack: %x\n", cpu_get_rsp(), (uint64_t)initstack);

    const void* stack_src_virt_ptr = (void*)((UINT64_MAX - (uint64_t)initstack) + 1);

    memcpy(stack_src_virt_ptr, vm_kernel_stack.phys_address, (uint64_t)initstack);

    vm_map_phys_to_virt(vm_kernel_stack.phys_address,
                        vm_kernel_stack.virt_address,
                        vm_kernel_stack.size / PAGE_BYTE_SIZE,
                        (VMMAP_FORCE | VMMAP_USE_LARGE_PAGES));
    //

    // Map framebuffer

    //

    // Map kernel

    //

    // Map bootboot mmap entries

    //
    
    // Enable new page tabels

    //kernel_warn("OS Page tables enabled!\n");

    return KERNEL_OK;
}

Status vm_map_phys_to_virt(const uint64_t phys_addr, const uint64_t virt_addr, const size_t pages_count, VMMapFlags flags) {
    return KERNEL_OK;
}