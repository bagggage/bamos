#include "arch.h"

#include "boot.h"
#include "logger.h"

#include "utils/mem.h"

#include "vm/vm.h"

static OMA page_table_oma;

Status Arch_x86_64::vm_init() {
    constexpr auto pt_pool_pages = 512;
    void* const oma_pool = Boot::alloc(pt_pool_pages);

    if (oma_pool == Boot::alloc_fail) [[unlikely]] {
        error("Failed to allocate memory for VM page table pool");
        return KERNEL_ERROR;
    }

    const auto virt_oma_pool = VM::get_virt_dma(oma_pool);

    page_table_oma = OMA(sizeof(PageTableEntry) * page_table_size, virt_oma_pool, pt_pool_pages);
    page_table_oma.log();

    return KERNEL_OK;
}

Arch_x86_64::PageTableEntry::PageTableEntry(const uintptr_t base, const uint8_t flags) {
    present = 1;

    accessed    = 0;
    dirty       = 0;
    reserved_1  = 0;
    ignored_1   = 0;
    ignored_2   = 0;

    write_through   = 0;

    writeable       = (flags & VM::MMAP_WRITE) ? 1 : 0;
    user_access     = (flags & VM::MMAP_USER) ? 1 : 0;
    global          = (flags & VM::MMAP_GLOBAL) ? 1 : 0;
    cache_disabled  = (flags & VM::MMAP_CACHE_DISABLE) ? 1 : 0;
    exec_disabled   = (flags & VM::MMAP_EXEC) ? 0 : 1;
    size            = (flags & VM::MMAP_LARGE) ? 1 : 0;

    page_ppn = base / page_size;
}

void Arch_x86_64::PageTableEntry::prioritize_flags(const uint8_t flags) {
    writeable       |= ((flags & VM::MMAP_WRITE) != 0);
    user_access     |= ((flags & VM::MMAP_USER) != 0);
    exec_disabled   &= ((flags & VM::MMAP_EXEC) == 0);
    cache_disabled  &= ((flags & VM::MMAP_CACHE_DISABLE) != 0);
}

PageTable* PageTable::alloc() {
    PageTable* const pte = reinterpret_cast<PageTable*>(page_table_oma.alloc());

    if (pte) fill(reinterpret_cast<uint64_t*>(pte), 0ul, page_table_size);

    return pte;
}

void PageTable::free(PageTable* const page_table) {
    if (page_table == nullptr) [[unlikely]] return;

    page_table_oma.free(page_table);
}

static inline uint16_t get_pxe_idx(const uint8_t pt_idx, const uintptr_t virt_addr) {
    return (virt_addr >> ((pt_idx * 9) + 12)) & 0x1FF;
}

static inline uint64_t get_inpage_offset(const uint8_t pt_idx, const uintptr_t virt_addr) {
    return virt_addr & (~((~0xFFFul) << (pt_idx * 9)));
}

uintptr_t Arch_x86_64::get_phys(const PageTable* page_table, const uintptr_t virt_addr) {
    const PageTableEntry* pt_entry = &page_table[get_pxe_idx(3, virt_addr)];

    for (auto pt_idx = 0u; pt_idx < 4; pt_idx++) {
        if (pt_entry->present == 0) break;

        if (pt_entry->size || pt_idx == 3) {
            return pt_entry->get_base() | get_inpage_offset(3 - pt_idx, virt_addr);
        }

        pt_entry = pt_entry->get_next() + get_pxe_idx(2 - pt_idx, virt_addr);
    }

    return invalid_phys;
}

using PageTableEntry = Arch_x86_64::PageTableEntry;

namespace logging {
    static const char* prefixies[] = { "", "---|---|---", "---|---", "---" };
    static const char* size_strs[] = { "", " KB", " MB", " GB" };
    static const uint64_t size_steps[] = { 0, KB_SIZE * 4, MB_SIZE * 2, GB_SIZE };
    static const uint32_t size_units[] = { 0, 4, 2, 1 };

    static void log_pte(const PageTableEntry* pte, const uintptr_t prev_base, const uint32_t pte_idx, const uint8_t level) {
        const auto prev_idx = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(pte) & 0xFFF) / 8;
        if (pte_idx - prev_idx > 1) {
            const auto last_idx = pte_idx == 511 ? pte_idx : pte_idx - 1;

            info('|', prefixies[level], 'P', level, " Entry [", prev_idx, '-', last_idx, "]: ",
                pte->get_base(), '-', prev_base + size_steps[level], ' ', (last_idx - prev_idx + 1) * size_units[level], size_strs[level]);
        }
        else {
            info('|', prefixies[level], 'P', level, " Entry [", prev_idx, "]: ", pte->get_base(), ' ', size_units, size_strs[level]);
        }
    }

    static void log_pt_helper(const PageTable* pt, const uint8_t level) {
        using PageTableEntry = Arch_x86_64::PageTableEntry;

        const PageTableEntry* pte = nullptr;
        uintptr_t prev_base = 0;

        for (auto pte_idx = 0u; pte_idx < Arch_x86_64::page_table_size; ++pte_idx) {
            const PageTableEntry& curr_pte = pt[pte_idx];

            if (curr_pte.present == 0) {
                if (pte) {
                    log_pte(pte, prev_base, pte_idx, level);
                    pte = nullptr;
                }
                continue;
            }

            if (pte && (curr_pte.size || level == 1)) {
                if (curr_pte.get_base() == prev_base + size_steps[level] &&
                    curr_pte.writeable == pte->writeable && curr_pte.exec_disabled == pte->exec_disabled) {
                    prev_base += size_steps[level];

                    if (pte_idx == 511) [[unlikely]] log_pte(pte, prev_base, pte_idx, level);
                    continue;
                }

                kassert(pte->size || level == 1);

                log_pte(pte, prev_base, pte_idx, level);

            pte_next_base:
                pte = &curr_pte;
                prev_base = curr_pte.get_base();

                if (pte_idx == 511) log_pte(pte, prev_base, pte_idx, level);
                continue;
            }
            else if (curr_pte.size || level == 1) {
                goto pte_next_base;
            }

            if (pte) {
                log_pte(pte, prev_base, pte_idx, level);
                pte = nullptr;
            }

            warn('`', prefixies[level], 'P', level, " Entry [", pte_idx, "]: ", VM::get_phys_dma(&curr_pte), " -> ", curr_pte.get_base());

            if (level > 1) log_pt_helper(curr_pte.get_next(), level - 1);
        }
    }
}

void Arch_x86_64::log_pt(const PageTable* page_table) {
    for (auto p4_idx = 0u; p4_idx < page_table_size; ++p4_idx) {
        const PageTableEntry& p4e = page_table[p4_idx];

        if (p4e.present == 0) continue;

        warn("P4 Entry [", p4_idx, "]: ", VM::get_phys_dma(&p4e));

        const PageTable* p3t = p4e.get_next();

        logging::log_pt_helper(p3t, 3);
    }
}

static constexpr auto pages_per_2_mb = ((2 * MB_SIZE) / Arch::page_size);

static inline uint8_t make_mmap_flags(uint8_t raw_flags, const uintptr_t virt, const uintptr_t phys, const uint32_t pages) {
    uint8_t result = raw_flags;

    if (raw_flags & VM::MMAP_LARGE) {
        if (pages < pages_per_2_mb ||
            (virt % (2 * MB_SIZE) != 0 || phys % (2 * MB_SIZE) != 0)
        ) {
            result ^= VM::MMAP_LARGE;
        }
    }

    return result;
}

bool Arch_x86_64::remap_large(PageTableEntry* pte, const bool is_gb_page) {
    PageTableEntry template_pte = *pte;
    template_pte.size = is_gb_page ? 1 : 0;

    PageTable* pt = PageTable::alloc();
    if (pt == PageTable::alloc_fail) return false;

    pte->page_ppn = VM::get_phys_dma(reinterpret_cast<uintptr_t>(pt)) / page_size;
    pte->size = 0;
    pte->global = 0;

    const auto pages_step = is_gb_page ? pages_per_2_mb : 1;

    for (auto i = 0u; i < page_table_size; ++i) {
        auto& entry = pt[i];

        entry = template_pte;
        template_pte.page_ppn += pages_step;
    }
    
    return true;
}

bool Arch_x86_64::early_mmap_dma() {
    PageTable* pt = VM::get_phys_dma(get_page_table());
    const auto p4_idx = get_pxe_idx(3, dma_start);
    PageTable* pt3 = reinterpret_cast<PageTable*>(Boot::alloc(1));

    {
        if (pt3 == Boot::alloc_fail) return false;

        auto& pte = pt[p4_idx];

        pte = PageTableEntry(reinterpret_cast<uintptr_t>(pt3), VM::MMAP_WRITE);
        uint64_t val = *reinterpret_cast<uint64_t*>(&pte);
    }

    PageTableEntry template_pte(static_cast<uintptr_t>(0), (VM::MMAP_GLOBAL | VM::MMAP_LARGE | VM::MMAP_WRITE));

    for (auto i = 0u; i < (dma_size / GB_SIZE); ++i) {
        pt3[i] = template_pte;
        template_pte.page_ppn += (GB_SIZE / page_size);
    }

    return true;
}

uintptr_t Arch_x86_64::mmap(
    const uintptr_t virt, const uintptr_t phys,
    const uint32_t pages, const uint8_t flags,
    PageTable* const page_table
) {
    uint8_t temp_flags = make_mmap_flags(flags, virt, phys, pages);

    PageTableEntry template_pte(phys, temp_flags);

    PageTableEntry* pt_stack[4] = { nullptr, nullptr, nullptr, nullptr };

    uint16_t pte_idx = get_pxe_idx(3, virt);
    PageTableEntry* pte = &page_table[pte_idx];

    uint32_t max_pt = 3;

    if (temp_flags & VM::MMAP_LARGE) {
        max_pt = 2;

        if (pages >= (GB_SIZE / page_size) && (virt % GB_SIZE) == 0 && (phys % GB_SIZE) == 0)
            max_pt = 1;
    }

    //debug("virt: ", virt, ": phys: ", phys, ": flags: ", flags, ": temp flags: ", temp_flags, ": max pt: ", max_pt);

    uint32_t mapped_pages = 0;

    for (auto pt_idx = 0u; pt_idx < 4;) {
        if (pt_idx < max_pt) {
            // Just lookup next entry in next page table

            if (pte->present == 0) {
                // Allocate new page table if not present
                PageTable* new_pt = PageTable::alloc();
                if (new_pt == PageTable::alloc_fail) return 0;

                *pte = template_pte;
                pte->size = 0;
                pte->global = 0;
                pte->page_ppn = VM::get_phys_dma(reinterpret_cast<uintptr_t>(new_pt)) / page_size;
            }
            else if (pte->size) {
                // Remap large page
                if (remap_large(pte, pt_idx == 1) == false) return 0;
                pte->prioritize_flags(temp_flags);
            }
            else {
                pte->prioritize_flags(temp_flags);
            }

            // Push next to the current pte on the stack
            if (pte_idx == 511) [[unlikely]] pt_stack[pt_idx] = nullptr;
            else [[likely]] pt_stack[pt_idx] = pte + 1;

            //debug("pt: ", VM::get_phys_dma(pte), " -> ", pte->get_next());

            // Go to the next pte in the next page table
            pte_idx = mapped_pages == 0 ? get_pxe_idx(2 - pt_idx, virt) : 0;
            pte = pte->get_next() + pte_idx;
            pt_idx++;
        }
        else {
            // Begin mapping
            uint32_t entries_to_map = pages - mapped_pages;
            uint32_t pages_step = 1;

            if (temp_flags & VM::MMAP_LARGE) {
                switch (max_pt) {
                case 1:
                    entries_to_map /= (GB_SIZE / page_size);
                    pages_step = (GB_SIZE / page_size);
                    break;
                case 2:
                    entries_to_map /= pages_per_2_mb;
                    pages_step = pages_per_2_mb;
                    break;
                default: kassert(false);
                }
            }

            for (; entries_to_map > 0 && pte_idx < page_table_size; ++pte_idx, --entries_to_map) {
                //debug("mmap: ", VM::get_phys_dma(pte), ": -> ", (template_pte.page_ppn + mapped_pages) * page_size, template_pte.size ? " (large)" : " (page)");

                *pte = template_pte;
                pte->page_ppn += mapped_pages;

                mapped_pages += pages_step;
                pte++;
            }

            if (entries_to_map == 0) {
                kassert(mapped_pages <= pages);

                if (mapped_pages == pages) return virt;

                kassert(temp_flags & VM::MMAP_LARGE);

                if (max_pt == 2) {
                    temp_flags ^= VM::MMAP_LARGE;
                    template_pte.size = 0;
                }

                max_pt++;
            }

            kassert(pte_idx == 512);

            while (pt_stack[pt_idx - 1] == nullptr) { kassert(pt_idx > 0); --pt_idx; }

            pte = pt_stack[--pt_idx];
            pte_idx = (reinterpret_cast<uintptr_t>(pte) & 0xFFF) / sizeof(PageTableEntry);

            kassert(pte_idx > 0);
        }
    }

    return invalid_virt;
}

void Arch_x86_64::unmap(
    const uintptr_t virt,
    const uint32_t pages,
    PageTable* const page_table
) {
     
}

void Arch_x86_64::map_ctrl(
    const uintptr_t virt,
    const uint32_t pages,
    const uint8_t flags,
    PageTable* const page_table
) {

}