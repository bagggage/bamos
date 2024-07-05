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

#include <libc/errno.h>

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
    return !(prog->virt_address + prog->memory_size + USER_SPACE_ADDR_BEGIN >= KERNEL_HEAP_VIRT_ADDRESS ||
            prog->memory_size == 0 || prog->file_size > prog->memory_size ||
            (prog->flags & (ELF_PROG_FLAGS_EXEC | ELF_PROG_FLAGS_READABLE)) == 0);
}

static int elf_load_prog(const ElfFile* elf_file, const ElfProgramHeader* prog, Process* const process) {
    kassert(prog != NULL && process != NULL && prog->type == ELF_PROG_TYPE_LOAD);

    //kernel_msg("Prog header type: %x\n", prog->type);
    //kernel_msg("Prog virt address: %x\n", prog->virt_address);
    //kernel_msg("Prog memory size: %x\n", prog->memory_size);
    //kernel_msg("Prog file size: %x\n", prog->file_size);
    //kernel_msg("Prog flags: %b\n", prog->flags);

    if (is_prog_section_valid(prog) == FALSE) return -ENOEXEC;

    VMMemoryBlockNode* segment = proc_push_segment(process);

    if (segment == NULL) return -ENOMEM;

    segment->block.pages_count = div_with_roundup((prog->virt_address & 0xFFF) + prog->memory_size, PAGE_BYTE_SIZE);
    segment->block.page_base = bpa_allocate_pages(
        log2upper(segment->block.pages_count)
    ) / PAGE_BYTE_SIZE;

    if (segment->block.page_base == 0) return -ENOMEM;

    segment->block.virt_address = prog->virt_address + elf_file->load_base;

    Status result = _vm_map_phys_to_virt(
        (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
        segment->block.virt_address,
        process->addr_space.page_table,
        segment->block.pages_count,
        VMMAP_USER_ACCESS |
        ((prog->flags & ELF_PROG_FLAGS_EXEC) ? VMMAP_EXEC : 0) |
        ((prog->flags & ELF_PROG_FLAGS_WRITEABLE) ? VMMAP_WRITE : 0)
    );

    //kernel_msg("  Pages count: %u: Base: %x: Top: %x\n",
    //    segment->block.pages_count,
    //    segment->block.virt_address,
    //    segment->block.virt_address + (segment->block.pages_count * PAGE_BYTE_SIZE)
    //);

    kassert(is_virt_addr_mapped(segment->block.virt_address));

    if (result != KERNEL_OK) {
        bpa_free_pages(
            (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
            log2upper(segment->block.pages_count)
        );
        return -ENOMEM;
    }

    const uint64_t phys_base = 
        ((uint64_t)segment->block.page_base * PAGE_BYTE_SIZE) |
        (segment->block.virt_address & 0xFFF);
    
    if (vfs_read(elf_file->dentry, prog->offset, prog->file_size, (void*)phys_base) < prog->file_size) {
        bpa_free_pages(
            (uint64_t)segment->block.page_base * PAGE_BYTE_SIZE,
            log2upper(segment->block.pages_count)
        );
        return -EIO;
    }

    if (prog->memory_size > prog->file_size) {
        memset(
            (void*)(phys_base + prog->file_size),
            prog->memory_size - prog->file_size,
            0
        );
    }

    return 0;
}

static int elf_load_exec(const ElfFile* elf_file, Process* const process) {
    kassert(elf_file->header->type == ELF_TYPE_EXEC);

    for (uint32_t i = 0; i < elf_file->header->prog_entries_count; ++i) {
        const ElfProgramHeader* prog = elf_file->progs + i;

        if (prog->type != ELF_PROG_TYPE_LOAD) continue;

        int result = 0;

        if ((result = elf_load_prog(elf_file, prog, process)) < 0) {
            proc_clear_segments(process);
            return result;
        }
    }

    return 0;
}

static bool_t elf_load_dyn_section(const ElfDynamicEntry* dyn, Process* const process) {
    while (dyn->tag != ELF_DYN_TAG_NULL) {
        dyn++;
    }

    return TRUE;
}

const ElfProgramHeader* elf_find_prog(const ElfFile* elf_file, const ElfProgramType prog_type) {
    for (uint32_t i = 0; i < elf_file->header->prog_entries_count; ++i) {
        const ElfProgramHeader* prog = elf_file->progs + i;

        if (prog->type == prog_type) return prog;
    }

    return NULL;
}

static int elf_load_dyn(const ElfFile* elf_file, Process* const process) {
    kassert(elf_file->header->type == ELF_TYPE_DYN);

    for (uint32_t i = 0; i < elf_file->header->prog_entries_count; ++i) {
        int result = 0;

        const ElfProgramHeader* prog = elf_file->progs + i;

        switch (prog->type)
        {
        case ELF_PROG_TYPE_LOAD: {
            result = elf_load_prog(elf_file, prog, process);
            break;
        }
        case ELF_PROG_TYPE_DYNAMIC: {
            //if (is_dyn_loaded) {
            //    is_success = FALSE;
            //    break;
            //}

            //const ElfDynamicEntry* dyn = (const ElfDynamicEntry*)((const uint8_t*)elf + prog->offset);

            //is_success = elf_load_dyn_section(dyn, process);
            //is_dyn_loaded = is_success;

            break;
        }
        default:
            break;
        }

        if (result < 0) {
            proc_clear_segments(process);
            return result;
        }
    }

    return 0;
}

static bool_t elf_load_reloc(const ELF* elf) {
    kassert(elf->type == ELF_TYPE_RELOC);

    return FALSE;   
}

int elf_read_file(ElfFile* const elf_file) {
    kassert(elf_file != NULL && elf_file->dentry != NULL && elf_file->dentry->inode->type == VFS_TYPE_FILE);

    // Read ELF header
    ELF* const elf = (ELF*)kmalloc(sizeof(ELF));

    if (elf == NULL) return -ENOMEM;
    if (vfs_read(elf_file->dentry, 0, sizeof(ELF), (void*)elf) < sizeof(ELF)) {
        kfree(elf);
        return -EIO;
    }

    // Read prog headers
    if (elf->prog_entries_count < 1) return -ENOEXEC;

    const uint32_t size = elf->prog_entries_count * sizeof(ElfProgramHeader);
    ElfProgramHeader* progs = (ElfProgramHeader*)kmalloc(size);

    if (progs == NULL) {
        kfree(elf);
        return -ENOMEM;
    }

    if (vfs_read(elf_file->dentry, elf->ph_offset, size, (void*)progs) < size) {
        kfree(elf);
        kfree(progs);
        return -EIO;
    }

    elf_file->header = elf;
    elf_file->progs = progs;

    return 0;
}

void elf_free_file(ElfFile* const elf_file) {
    kfree(elf_file->header);
    kfree(elf_file->progs);
}

int elf_load(const ElfFile* elf_file, Process* const process) {
    kassert(elf_file != NULL && process != NULL);

    UNUSED(elf_load_reloc);

    const ELF* elf = elf_file->header;

    if (elf->header_size != sizeof(ELF) || elf->ph_offset % 4 != 0 || elf->sh_offset % 4 != 0) return FALSE;

    int result = 0;

    switch (elf->type)
    {
    case ELF_TYPE_EXEC:
        result = elf_load_exec(elf_file, process);
        break;
    case ELF_TYPE_DYN:
        result = elf_load_dyn(elf_file, process);
        break;
    default:
        break;
    }

    return result;
}

static bool_t elf_test_log(const void* elf_file) {
    const ELF* elf = (const ELF*)elf_file;

    if (elf->header_size != sizeof(ELF) || elf->ph_offset % 4 != 0 || elf->sh_offset % 4 != 0) return -ENOEXEC;

    kernel_msg("ELF: %x\n", elf);
    kernel_msg("ELF Header size: %u\n", (uint32_t)elf->header_size);
    kernel_msg("ELF machine: %u\n", (uint32_t)elf->machine);
    kernel_msg("ELF program header offset: %x\n", elf->ph_offset);
    kernel_msg("ELF section header offset: %x\n", elf->sh_offset);

    const ElfSectionHeader* section = elf_get_section(elf, 1);

    kernel_msg("%x\n", section);

    for (uint32_t i = 1; i < elf->sect_entries_count; ++i) {
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