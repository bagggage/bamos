#include "uma.h"

#include "bpa.h"
#include "vm.h"

size_t UMA::allocated_bytes = 0;
OMA UMA::oma_pool[];
UMA::Tree_t UMA::large_allocs;

Status UMA::init() {
    for (auto i = 0u; i < max_small_rank; ++i) {
        const auto obj_size = 1u << (i + min_rank);
        uint32_t capacity = Arch::page_size / obj_size;

        if (capacity < 16) capacity *= 2;

        oma_pool[i] = OMA(obj_size, capacity);
    }

    return KERNEL_OK;
}

void* UMA::alloc(const uint32_t size) {
    kassert(size > 0 && size <= max_alloc_size);

    void* result = nullptr;

    if (size > max_small_size) [[unlikely]] {
        const auto rank = log2upper(div_roundup(size, Arch::page_size));
        kassert(rank < BPA::max_rank);

        const auto phys_base = BPA::alloc_pages(rank);
        if (phys_base == BPA::alloc_fail) return nullptr;

        allocated_bytes += (1u << rank) * Arch::page_size;
        result = reinterpret_cast<void*>(VM::get_virt_dma(phys_base));

        large_allocs.insert(PhysPageFrame(phys_base, rank));
    }
    else {
        const auto rank = max(log2upper(size), min_rank) - min_rank;
        result = oma_pool[rank].alloc();

        if (result) allocated_bytes += (1u << (rank + min_rank));
    }

    return result;
}

void UMA::free(void* const ptr) {
    for (auto i = 0u; i < max_small_rank; ++i) {
        for (const auto& bucket : oma_pool[i].buckets) {
            if (bucket.is_containing_addr(ptr) == false) continue;

            oma_pool[i].free(ptr);

            allocated_bytes -= (1u << (i + min_rank));
            return;
        }
    }

    const uintptr_t phys_base = reinterpret_cast<uintptr_t>(VM::get_phys_dma(ptr));

    kassert((phys_base % Arch::page_size) == 0);

    PhysPageFrame frame = large_allocs.pop(phys_base / Arch::page_size);
    BPA::free_pages(phys_base, log2(frame.size));

    allocated_bytes -= frame.size * Arch::page_size;
}