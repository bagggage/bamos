#pragma once

#include "arch.h"
#include "definitions.h"
#include "heap.h"

#include "utils/list.h"

class VM {
public:
    struct PageFrame {
        PageFrame(uint32_t base, uint16_t size, bool is_base = true)
        : base(base), size(size), is_base(is_base)
        {}

        PageFrame(uintptr_t base, uint8_t rank)
        : base(base / Arch::page_size), size(1 << rank), is_base(true)
        {}

        uint32_t base;
        uint16_t size;

        bool is_base;

        inline uint32_t end() const { return base + size; }
    };

    class MemFrame {
    private:
        List<PageFrame> pages;
    public:
        inline const List<PageFrame>& get_pages() const { return pages; }
    };

    enum MapFlags : uint8_t {
        MMAP_NONE,
        MMAP_WRITE = 0x1,
        MMAP_EXEC = 0x2,
        MMAP_USER = 0x4,
        MMAP_LARGE = 0x8,
        MMAP_GLOBAL = 0x10,
        MMAP_CACHE_DISABLE = 0x20
    };
private:
    static Heap kernel_heap;
private:
    static bool remap_kernel(PageTable* const page_table);
public:
    static Status init();

    static inline uintptr_t get_virt_dma(const uintptr_t phys) {
        return phys + Arch::dma_start;
    }

    static inline void* get_virt_dma(const void* phys) {
        return reinterpret_cast<void*>(get_virt_dma(reinterpret_cast<uintptr_t>(phys)));
    }

    static inline uintptr_t get_phys_dma(const uintptr_t virt) {
        return virt - Arch::dma_start;
    }

    static inline void* get_phys_dma(const void* virt) {
        return reinterpret_cast<void*>(get_phys_dma(reinterpret_cast<uintptr_t>(virt)));
    }

    static inline uintptr_t get_phys(const uintptr_t virt_addr, const PageTable* page_table = Arch::get_page_table()) { 
        return Arch::get_phys(page_table, virt_addr);
    }

    static inline uintptr_t mmap(
        const uintptr_t virt, const uintptr_t phys,
        const uint32_t pages, const uint8_t flags,
        PageTable* const page_table = Arch::get_page_table()
    ) { return Arch::mmap(virt, phys, pages, flags, page_table); }

    static inline void unmap(
        const uintptr_t virt,
        const uint32_t pages,
        PageTable* const page_table = Arch::get_page_table()
    ) { Arch::unmap(virt, pages, page_table); }

    static inline void map_ctrl(
        const uintptr_t virt,
        const uint32_t pages,
        const uint8_t flags,
        PageTable* const page_table = Arch::get_page_table()
    ) { Arch::map_ctrl(virt, pages, flags, page_table); }

    static void* mmio(const uintptr_t phys_base, const uint32_t pages);
    static void unmmio(const void* virt, const uint32_t pages);

    static void* alloc(const uint32_t size);
    static void free(void* const ptr);
};