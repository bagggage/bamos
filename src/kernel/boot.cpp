#include "boot.h"

#include <bootboot.h>

#include "arch.h"
#include "assert.h"
#include "trace.h"

#include "vm/vm.h"

#include "video/fb.h"

/*
Kernel linking symbols.
Defined at `config/linker.ld`.
*/
extern BOOTBOOT bootboot;
extern int mmio; // Ignored
extern int fb;
extern int environment;
extern int initstack; // CPU Stack size
extern int kernel_elf_start;
extern int kernel_elf_end;

BootMemMap Boot::mem_map;

ColorFormat bootboot_make_color_fmt(const uint8_t fb_type) {
    switch (fb_type)
    {
    case FB_ABGR: return ABGR;
    case FB_ARGB: return ARGB;
    case FB_BGRA: return BGRA;
    case FB_RGBA: return RGBA;
    default:
        break;
    }

    return RGBA;
}

void Boot::get_fb(Framebuffer* const fb_ptr) {
    *fb_ptr = Framebuffer(
        reinterpret_cast<uintptr_t>(&fb),
        bootboot.fb_scanline,
        bootboot.fb_width,
        bootboot.fb_height,
        bootboot_make_color_fmt(bootboot.fb_type)
    );
}

uint32_t Boot::get_cpus_num() {
    return bootboot.numcores;
}

const DebugSymbolTable* Boot::get_dbg_table() {
    static constexpr unsigned char sym_table_magic[] = { 0xAC, 'D', 'B', 'G' };
    static constexpr uint32_t second_part_magic = 0xFE015223;

    const uint8_t* ptr = reinterpret_cast<uint8_t*>(bootboot.initrd_ptr);

    while (reinterpret_cast<uintptr_t>(ptr) < bootboot.initrd_ptr + bootboot.initrd_size) {
        if (*(const uint32_t*)ptr == *(const uint32_t*)sym_table_magic) {
            if (*(const uint32_t*)(ptr + sizeof(uint32_t)) == second_part_magic) {
                return reinterpret_cast<const DebugSymbolTable*>(ptr);
            }
        }

        ptr++;
    }

    return nullptr;
}

uint32_t Boot::calc_mmap_size() {
    return (
        bootboot.size -
        (reinterpret_cast<uint64_t>(&bootboot.mmap) -
        reinterpret_cast<uint64_t>(&bootboot))
    ) / sizeof(MMapEnt);
}

void* Boot::early_alloc(const uint32_t pages_num) {
    const uint32_t size = calc_mmap_size();

    MMapEnt* const entries = &bootboot.mmap;

    for (uint32_t i = 0; i < size; ++i) {
        if ((MMapEnt_Size(entries + i) / Arch::page_size) >= pages_num) {
            const uintptr_t result = (
                MMapEnt_Ptr(entries + i) + MMapEnt_Size(entries + i) -
                (pages_num * Arch::page_size)
            );

            entries[i].size = (
                (MMapEnt_Size(entries + i) - (pages_num * Arch::page_size)) |
                MMapEnt_Type(entries + i)
            );

            return reinterpret_cast<void*>(result);
        }
    }

    return nullptr;
}

void Boot::init_mem_map() {
    mem_map.size = calc_mmap_size();
    mem_map.entries = reinterpret_cast<BootMemMap::Entry*>(early_alloc(1));

    uint32_t invalid_ents_num = 0;
    uint32_t j = 0;

    for (uint32_t i = 0; i < mem_map.size; ++i) {
        const MMapEnt* boot_ent = &bootboot.mmap + i;
        BootMemMap::Entry& ent = mem_map.entries[j];

        if (MMapEnt_Size(boot_ent) == 0) [[unlikely]] continue;

        if ((MMapEnt_Size(boot_ent) % Arch::page_size) > 0 ||
            (MMapEnt_Ptr(boot_ent) % Arch::page_size) > 0
        ) [[unlikely]] {
            invalid_ents_num++;
            continue;
        }

        ent.base = MMapEnt_Ptr(boot_ent) / Arch::page_size;
        ent.pages = MMapEnt_Size(boot_ent) / Arch::page_size;

        switch (MMapEnt_Type(boot_ent)) {
        case MMAP_ACPI: [[fallthrough]];
        case MMAP_MMIO: ent.type = BootMemMap::Type::MEM_DEV; break;
        case MMAP_USED: ent.type = BootMemMap::Type::MEM_USED; break;
        case MMAP_FREE: ent.type = BootMemMap::Type::MEM_FREE; break;
        default: ent.type = BootMemMap::Type::MEM_USED; break;
        }

        j++;
    }

    mem_map.size = j;

    if (invalid_ents_num) {
        error("Invalid memory map entries: ", invalid_ents_num);
    }
}

BootMemMapping* Boot::get_mem_mappings() {
    static BootMemMapping* mem_mappings = nullptr;

    if (mem_mappings == nullptr) {
        mem_mappings = reinterpret_cast<BootMemMapping*>(alloc(1));

        enum MemMappingsOrder {
            MAP_FRAMEBUFFER = 0,
            MAP_BOOTBOOT,
            MAP_KERNEL,
            MAP_ENVIRONMENT,
            MAP_STACK
        };

        mem_mappings[MAP_FRAMEBUFFER] = { 
            .phys = bootboot.fb_ptr,
            .virt = BOOTBOOT_FB,
            .pages = (16 * MB_SIZE) / Arch::page_size,
            .flags = (VM::MMAP_LARGE | VM::MMAP_WRITE)
        };
        mem_mappings[MAP_BOOTBOOT] = {
            .phys = VM::get_phys(reinterpret_cast<uintptr_t>(&bootboot)),
            .virt = reinterpret_cast<uintptr_t>(&bootboot),
            .pages = 1,
            .flags = VM::MMAP_WRITE
        };
        mem_mappings[MAP_KERNEL] = {
            .phys = VM::get_phys(reinterpret_cast<uintptr_t>(&kernel_elf_start)),
            .virt = reinterpret_cast<uintptr_t>(&kernel_elf_start),
            .pages = static_cast<uint32_t>(div_roundup(
                reinterpret_cast<uint64_t>(&kernel_elf_end) -
                reinterpret_cast<uint64_t>(&kernel_elf_start),
                Arch::page_size
            )),
            .flags = (VM::MMAP_WRITE | VM::MMAP_EXEC)
        };
        mem_mappings[MAP_ENVIRONMENT] = {
            .phys = VM::get_phys(reinterpret_cast<uintptr_t>(&environment)),
            .virt = reinterpret_cast<uintptr_t>(&environment),
            .pages = 1,
            .flags = VM::MMAP_WRITE
        };

        // Stacks
        const auto stack_size = reinterpret_cast<uintptr_t>(&initstack);
        const auto stacks_pages = div_roundup(bootboot.numcores * stack_size, Arch::page_size);
        const auto stack_base = UINTPTR_MAX - Arch::page_size;

        for (auto i = 0u; i < stacks_pages; ++i) {
            const auto base = stack_base - (i * Arch::page_size);

            mem_mappings[MAP_STACK + i] = {
                .phys = VM::get_phys(base),
                .virt = base,
                .pages = 1,
                .flags = VM::MMAP_WRITE
            };
        }
    }

    return mem_mappings;
}

void BootMemMap::remove(const uint32_t idx) {
    kassert(idx < size);

    if (idx == size - 1) {
        size--;
        return;
    }

    for (uint32_t i = idx; i < size - 1; ++i) entries[i] = entries[i + 1];
}

void* Boot::alloc(const uint32_t pages_num) {
    if (mem_map.is_empty()) init_mem_map();

    for (uint32_t i = 0; i < mem_map.size; ++i) {
        if (mem_map.entries[i].pages < pages_num) continue;

        const uint64_t base = 
            mem_map.entries[i].base +
            mem_map.entries[i].pages -
            pages_num;
        
        if (base == mem_map.entries[i].base) mem_map.remove(i);

        mem_map.entries[i].pages -= pages_num;

        return reinterpret_cast<void*>(base * Arch::page_size);
    }

    return nullptr;
}