#include "vm.h"

#include "assert.h"
#include "boot.h"
#include "bpa.h"

#include "utils/mem.h"

Heap VM::kernel_heap;

Status VM::init() {
    if (Arch::vm_init() != KERNEL_OK) return KERNEL_ERROR;

    PageTable* const kernel_pt = PageTable::alloc();

    if (kernel_pt == PageTable::alloc_fail) {
        error("Failed to allocate kernel page table");
        return KERNEL_ERROR;
    }

    if (remap_kernel(kernel_pt) == false) return KERNEL_ERROR;

    Arch::set_page_table(kernel_pt);
    Boot::switch_to_dma();

    if (BPA::init() != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

void* VM::mmio(const uintptr_t phys_base, const uint32_t pages) {
    kassert(pages > 0);
    kassert((phys_base % Arch::page_size == 0) && "Address must be a page aligned");

    const uintptr_t virt = kernel_heap.reserve(pages);

    if (virt == 0) return nullptr;

    const auto result = mmap(virt, phys_base, pages, (MMAP_GLOBAL | MMAP_WRITE | MMAP_CACHE_DISABLE));

    if (result == Arch::invalid_virt) [[unlikely]] return nullptr;

    return reinterpret_cast<void*>(result);
}

bool VM::remap_kernel(PageTable* const page_table) {
    BootMemMapping* const mappings = Boot::get_mem_mappings();

    if (mappings == nullptr) {
        error("Failed to get mappings from `Boot` module to map kernel page table");
        return false;
    }

    for (auto i = 0u; mappings[i].pages > 0; ++i) {
        const auto& mapping = mappings[i];

        if (mmap(mapping.virt, mapping.phys, mapping.pages, mapping.flags, page_table) == false) {
            error("Failed to map: ", mapping.virt, " -> ", mapping.phys, ": ", (mapping.pages * Arch::page_size / KB_SIZE), " KB");
            return false;
        }
    }

    return true;
}

void VM::unmmio(const void* virt, const uint32_t pages) {
    kassert(virt != nullptr && pages > 0);

    const auto temp_virt = reinterpret_cast<uintptr_t>(virt);

    kernel_heap.release(temp_virt, pages);

    // It is a lazy unmap, so we don't have to unmap the region directly,
    // it will be remapped for the next allocation.
}