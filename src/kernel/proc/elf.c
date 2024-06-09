#include "elf.h"

#include "assert.h"
#include "local.h"
#include "logger.h"
#include "mem.h"
#include "proc.h"

#include "math.h"

#include "vm/heap.h"
#include "vm/vm.h"
#include "vm/buddy_page_alloc.h"

#define ELF_SECTION_NAME_UNDEFINED 0

bool_t is_elf_valid(const ELF* elf) {
    return *(const uint32_t*)elf->ident_magic == ELF_MAGIC;
}

bool_t is_elf_supported(const ELF* elf) {
    return elf->ident_arch == ELF_IDENT_ARCH_X64 &&
        (elf->machine == ELF_MACHINE_IA64 ||
        elf->machine == ELF_MACHINE_AMD_X86_64);
}

static inline const ElfSectionHeader* elf_get_section(const ELF* elf, const uint32_t section_idx) {
    return ((const ElfSectionHeader*)((uint64_t)elf + elf->sh_offset)) + section_idx;
}

static inline const ElfProgramHeader* elf_get_prog_header(const ELF* elf, const uint32_t prog_idx) {
    return ((const ElfProgramHeader*)((uint64_t)elf + elf->ph_offset)) + prog_idx;
}

static inline const char* elf_get_str_table(const ELF* elf) {
	if (elf->sect_names_entry_idx == ELF_SECTION_NAME_UNDEFINED) return NULL;

	return (const char*)elf + elf_get_section(elf, elf->sect_names_entry_idx)->offset;
}

static inline const char* elf_lookup_string(const ELF* elf, const uint32_t offset) {
	const char *string_table = elf_get_str_table(elf);

	if (string_table == NULL) return NULL;

	return string_table + offset;
}

static inline bool_t is_prog_section_valid(const ElfProgramHeader* prog) {
    return !(prog->virt_address + prog->memory_size >= KERNEL_HEAP_VIRT_ADDRESS ||
            prog->virt_address == 0 || prog->virt_address < USER_SPACE_ADDR_BEGIN ||
            prog->memory_size == 0 || prog->file_size > prog->memory_size ||
            (prog->flags & (ELF_PROG_FLAGS_EXEC | ELF_PROG_FLAGS_READABLE)) == 0);
}

static bool_t elf_load_exec(const ELF* elf, Process* const process) {
    kassert(elf->type == ELF_TYPE_EXEC);

    //kernel_msg("Program header entries count: %u\n", elf->prog_header_entries_count);

    if (elf->prog_header_entries_count == 0) return FALSE;

    for (uint32_t i = 0; i < elf->prog_header_entries_count; ++i) {
        const ElfProgramHeader* prog = elf_get_prog_header(elf, i);

        //kernel_msg("Prog header type: %x\n", prog->type);
        //kernel_msg("Prog virt address: %x\n", prog->virt_address);
        //kernel_msg("Prog memory size: %x\n", prog->memory_size);
        //kernel_msg("Prog file size: %x\n", prog->file_size);
        //kernel_msg("Prog flags: %b\n", prog->flags);

        if (prog->type != ELF_PROG_TYPE_LOAD) continue;

        if (is_prog_section_valid(prog) == FALSE) {
            proc_clear_segments(process);
            return FALSE;
        }

        VMMemoryBlockNode* segment = proc_push_segment(process);

        if (segment == NULL) {
            proc_clear_segments(process);
            return FALSE;
        }

        segment->block.pages_count = div_with_roundup(prog->memory_size, PAGE_BYTE_SIZE);
        segment->block.page_base = bpa_allocate_pages(
            log2upper(segment->block.pages_count)
        ) / PAGE_BYTE_SIZE;

        if (segment->block.page_base == 0) {
            proc_clear_segments(process);
            return FALSE;
        }

        segment->block.virt_address = prog->virt_address;

        Status result = _vm_map_phys_to_virt(
            (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
            segment->block.virt_address,
            process->addr_space.page_table,
            segment->block.pages_count,
            VMMAP_USER_ACCESS |
            ((prog->flags & ELF_PROG_FLAGS_EXEC) ? VMMAP_EXEC : 0) |
            ((prog->flags & ELF_PROG_FLAGS_WRITEABLE) ? VMMAP_WRITE : 0)
        );

        if (result != KERNEL_OK) {
            bpa_free_pages(
                (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
                log2upper(segment->block.pages_count)
            );
            proc_clear_segments(process);
            return FALSE;
        }

        const uint8_t* segment_ptr = (const uint8_t*)elf + prog->offset;

        memcpy((const void*)segment_ptr, (void*)segment->block.virt_address, prog->memory_size);

        if (prog->memory_size > prog->file_size) {
            memset(
                (void*)(segment->block.virt_address + prog->file_size),
                prog->memory_size - prog->file_size,
                0
            );
        }
    }

    return TRUE;
}

static bool_t elf_load_reloc(const ELF* elf) {
    kassert(elf->type == ELF_TYPE_RELOC);

    return FALSE;   
}

static bool_t elf_load_dyn(const ELF* elf) {
    kassert(elf->type == ELF_TYPE_DYN);

    return FALSE;
}

ELF* elf_load_file(VfsDentry* const file_dentry) {
    kassert(file_dentry != NULL && file_dentry->inode != NULL);

    if (file_dentry->inode->file_size < sizeof(ELF) + sizeof(ElfProgramHeader)) return FALSE;

    ELF* result = (ELF*)kmalloc(file_dentry->inode->file_size);

    if (result == NULL) return NULL;

    const uint64_t readed = vfs_read(file_dentry, 0, file_dentry->inode->file_size, (void*)result);

    if (readed != file_dentry->inode->file_size) {
        kfree(result);
        return FALSE;
    }

    return result;
}

bool_t elf_load_prog(const ELF* elf, Process* const process) {
    UNUSED(elf_load_reloc);
    UNUSED(elf_load_dyn);

    if (elf->header_size != sizeof(ELF) || elf->ph_offset % 4 != 0 || elf->sh_offset % 4 != 0) return FALSE;

    bool_t result = FALSE;

    switch (elf->type)
    {
    case ELF_TYPE_EXEC:
        result = elf_load_exec(elf, process);
        break;
    default:
        break;
    }

    return result;
}

static bool_t elf_test_log(const void* elf_file) {
    const ELF* elf = (const ELF*)elf_file;

    if (elf->header_size != sizeof(ELF) || elf->ph_offset % 4 != 0 || elf->sh_offset % 4 != 0) return FALSE;

    kernel_msg("ELF: %x\n", elf);
    kernel_msg("ELF Header size: %u\n", (uint32_t)elf->header_size);
    kernel_msg("ELF machine: %u\n", (uint32_t)elf->machine);
    kernel_msg("ELF program header offset: %x\n", elf->ph_offset);
    kernel_msg("ELF section header offset: %x\n", elf->sh_offset);

    const ElfSectionHeader* section = elf_get_section(elf, 1);

    kernel_msg("%x\n", section);

    for (uint32_t i = 1; i < elf->sect_header_entries_count; ++i) {
        kernel_msg("Section: %s size: %x: offset: %x: address: %x\n",
            elf_lookup_string(elf, section->name_offset),
            section->size,
            section->offset,
            section->virt_address);

        section++;
    }

    return TRUE;
}

void elf_test(VfsDentry* const file_dentry) {
    uint8_t* buffer = (uint8_t*)kmalloc(8 * KB_SIZE);

    if (buffer == NULL) {
        kernel_error("Not enough memory\n");
        return;
    }

    for (int i = 0; i < 8; ++i) {
        vfs_read(file_dentry, i * KB_SIZE, KB_SIZE, (void*)(buffer + (i * KB_SIZE)));
    }

    if (buffer[0] != 0x7F) {
        kernel_error("Wrong read\n");
        return;
    }

    if (elf_test_log(buffer) == FALSE) {
        kernel_warn("ELF Test failed\n");
    }
    else {
        kernel_warn("ELF Test passed\n");
    }
}