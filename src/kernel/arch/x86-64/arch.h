#pragma once

#include "definitions.h"
#include "intr.h"

class Arch_x86_64 {
public:
    static constexpr uint64_t page_size = 4096;
    static constexpr auto page_table_size = 512u;
    static constexpr uintptr_t invalid_phys = 0xF000000000000000;
public:
    using Intr = Intr_x86_64;

    struct ATTR_PACKED StackFrame {
        StackFrame* next;
        uintptr_t ret_ptr;
    };

    struct PageTableEntry {
    public:
        uint64_t present            : 1; // If set, means next level page entry can be accessed
        uint64_t writeable          : 1; // If set, read/write allowed, otherwise read-only
        uint64_t user_access        : 1; // If set, allow user access
        uint64_t write_through      : 1;
        uint64_t cache_disabled     : 1;
        uint64_t accessed           : 1;
        uint64_t dirty              : 1;
        uint64_t size               : 1; // If set, for P3 size == 1GB; P2 size == 2MB
        uint64_t global             : 1;
        uint64_t ignored_2          : 3;
        uint64_t page_ppn           : 28; // Page table base physical address
        uint64_t reserved_1         : 12; // Must be 0
        uint64_t ignored_1          : 11;
        uint64_t exec_disabled : 1;  // If set, then execution disabled 
    public:
        PageTableEntry() = default;
        PageTableEntry(const uintptr_t base, const uint8_t flags);
        PageTableEntry(const PageTableEntry* base, const uint8_t flags)
        : PageTableEntry(reinterpret_cast<uintptr_t>(base), flags)
        {}

        inline uint64_t get_base() const {
            return page_ppn * page_size;
        }

        inline PageTableEntry* get_next() const {
            return reinterpret_cast<PageTableEntry*>(get_base());
        }

        void prioritize_flags(const uint8_t flags);

        static PageTableEntry* alloc();
        static void free(PageTableEntry* const);
    };

    using PageTable = PageTableEntry;
private:
    static void remap_large(PageTableEntry* pte, const bool is_gb_page);
public:
    static void preinit();

    static uint32_t get_cpu_idx();

    static Status vm_init();

    static inline PageTable* get_page_table() {
        uint64_t cr3;
        asm volatile("mov %%cr3,%0":"=g"(cr3));

        return reinterpret_cast<PageTable*>(cr3 & (~0xFFFul));
    }

    static uintptr_t get_phys(const PageTable* page_table, const uintptr_t virt_addr);

    static void log_pt(const PageTable* page_table);

    static uintptr_t mmap(
        const uintptr_t virt, const uintptr_t phys,
        const uint32_t pages, const uint8_t flags,
        PageTable* const page_table
    );

    static void unmap(
        const uintptr_t virt,
        const uint32_t pages,
        PageTable* const page_table
    );

    static void map_ctrl(
        const uintptr_t virt,
        const uint32_t pages,
        const uint8_t flags,
        PageTable* const page_table
    );
};