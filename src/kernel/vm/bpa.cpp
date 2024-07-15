#include "bpa.h"

#include "arch.h"
#include "assert.h"
#include "boot.h"
#include "logger.h"
#include "vm.h"

#include "utils/mem.h"
#include "utils/algorithm.h"

BPA::FreeArea BPA::areas[];
Spinlock BPA::lock = Spinlock();
uint32_t BPA::allocated_pages = 0;

bool BPA::push_free_entry(const uint32_t base, const uint32_t size) {
    uint32_t temp_base = base;
    uint32_t temp_size = size;

    while (temp_size != 0) {
        uint32_t temp_rank = log2(temp_size);

        if (temp_rank >= max_areas) temp_rank = max_areas - 1;

        uint32_t rank_page_count = (1u << temp_rank);

        while ((temp_base % rank_page_count) != 0) {
            temp_rank--;
            rank_page_count >>= 1;
        }

        areas[temp_rank].free_list.push_front(FreeEntry(temp_base));

        temp_base += rank_page_count;
        temp_size -= rank_page_count;
    }


    return true;
}

bool BPA::init_areas(uint8_t* bitmap_base, const uint32_t bitmap_size) {
    const BootMemMap& mem_map = Boot::get_mem_map();
    uint32_t temp_bitmap_size = bitmap_size;

    for (unsigned int i = 0; i < max_areas; ++i) {
        areas[i].bitmap = Bitmap(bitmap_base);

        temp_bitmap_size = max((temp_bitmap_size >> 1) + (temp_bitmap_size & 1), 1u);
        bitmap_base += temp_bitmap_size;
    }

    for (unsigned int i = 0; i < mem_map.size; ++i) {
        const BootMemMap::Entry& entry = mem_map.entries[i];

        if (entry.type != BootMemMap::Type::MEM_FREE) continue;
        if (push_free_entry(entry.base, entry.pages) != true) return false;
    }

    return true;
}

Status BPA::init() {
    BootMemMap& mem_map = Boot::get_mem_map();

    const uint32_t max_pages = mem_map.get_max_page() + 1;

    const uint32_t oma_bucket_pages = 1u << log2(div_roundup(max_pages * sizeof(List<FreeEntry>::Node), Arch::page_size) / 2);
    const uint32_t bitmap_size = div_roundup(max_pages, BYTE_SIZE);
    const uint32_t bitmap_pages = div_roundup(bitmap_size, Arch::page_size);

    const uint32_t mem_pool_pages = oma_bucket_pages + bitmap_pages;

    void* const mem_pool = Boot::alloc(mem_pool_pages);

    if (mem_pool == Boot::alloc_fail) {
        error("Failed to allocate memory bool for BPA: pages number: ", mem_pool_pages);
        return KERNEL_ERROR;
    }

    void* const virt_mem_pool = VM::get_virt_dma(mem_pool);

    {
        const uint32_t kb_per_page = Arch::page_size / KB_SIZE;

        info("BPA: max pages: ", max_pages, ", mem pool size: ", mem_pool_pages * kb_per_page, " KB");
        info("BPA: OMA pool: ", oma_bucket_pages * kb_per_page, " KB, nodes: ", max_pages / 2);
        info("BPA: bitmap: ", bitmap_pages * kb_per_page, " KB");
    }

    uint8_t* const bitmap_base = reinterpret_cast<uint8_t*>(virt_mem_pool) + (oma_bucket_pages * Arch::page_size);
    fill(bitmap_base, 0xFFu, bitmap_pages * Arch::page_size);

    auto& free_nodes_oma = FreeArea::List_t::Allocator::_get_oma();
    free_nodes_oma = OMA(sizeof(FreeArea::List_t::Node), virt_mem_pool, oma_bucket_pages);

    if (init_areas(bitmap_base, bitmap_size) == false) {
        error("Failed to fill free areas: not enough OMA capacity");
        return KERNEL_ERROR;
    }

    allocated_pages = mem_pool_pages;

    return KERNEL_OK;
}

uintptr_t BPA::alloc_pages(const unsigned rank) {
    kassert(rank < max_areas);

    lock.lock();

    uintptr_t result = 0;
    FreeEntry* free_entry = &areas[rank].free_list.get_head();

    if (free_entry == nullptr) [[unlikely]] {
        uint8_t temp_rank = rank + 1;

        while (temp_rank < max_areas) {
            if (areas[temp_rank].free_list.empty() == false) {
                free_entry = &areas[temp_rank].free_list.get_head();
                break;
            }

            temp_rank++;
        }

        if (free_entry == nullptr) [[unlikely]] {
            lock.release();
            return result;
        }

        uint32_t temp_number = (1 << (temp_rank - 1));
        uint32_t temp_base = free_entry->base;

        areas[temp_rank].free_list.pop_front();
        clear_page_bit(temp_base, temp_rank);

        areas[temp_rank - 1].free_list.push_front(FreeEntry(temp_base));
        set_page_bit(temp_base, temp_rank - 1);

        temp_rank--;
        temp_base += temp_number;

        while (temp_rank > rank) {
            temp_rank--;
            temp_number >>= 1;

            areas[temp_rank].free_list.push_front(FreeEntry(temp_base));
            set_page_bit(temp_base, temp_rank);

            temp_base += temp_number;
        }

        allocated_pages += (1u << rank);
        lock.release();

        result = static_cast<uintptr_t>(temp_base) * Arch::page_size;

        return result;
    }

    result = static_cast<uintptr_t>(free_entry->base) * Arch::page_size;
    inverse_page_bit(free_entry->base, rank);

    areas[rank].free_list.pop_front();
    allocated_pages += (1u << rank);

    lock.release();

    return result;
}

void BPA::free_pages(const uintptr_t base, const unsigned rank) {
    kassert((base & 0xFFF) == 0 && rank < max_areas);

    uint32_t page_base = static_cast<uint32_t>(base / Arch::page_size);

    lock.lock();

    // Check if buddy is used
    if (get_page_bit(page_base, rank) == 0 || rank == max_areas - 1) {
        areas[rank].free_list.push_front(FreeEntry(page_base));

        set_page_bit(page_base, rank);

        lock.release();
        return;
    }

    uint32_t temp_rank = rank;

    // Buddies can be combined
    while (get_page_bit(page_base, temp_rank) != 0 && temp_rank < (max_areas - 1)) {
        const uint32_t rank_pages_count = 1 << temp_rank;

        uint32_t combine_page_base = page_base;
        uint32_t buddy_base = page_base;

        if (page_base % (rank_pages_count << 1) == 0) {
            buddy_base += rank_pages_count;
        }
        else {
            buddy_base -= rank_pages_count;
            combine_page_base = buddy_base;
        }

        clear_page_bit(buddy_base, temp_rank);

        auto& list = areas[temp_rank].free_list;
        const auto& entry = find(list.begin(), list.end(), FreeEntry(buddy_base));

        for (auto it = list.begin(); it != list.end(); ++it) {
            debug(it->base * Arch::page_size);
        }

        kassert(entry != list.end());

        areas[temp_rank].free_list.remove(entry);

        page_base = combine_page_base;
        temp_rank++;
    }

    areas[temp_rank].free_list.push_front(FreeEntry(page_base));

    set_page_bit(page_base, temp_rank);
    allocated_pages -= (1u << rank);

    lock.release();
}