#pragma once

#include "definitions.h"

#include "oma.h"
#include "spinlock.h"

#include "utils/bitmap.h"
#include "utils/list.h"

class BPA {
private:
    struct FreeEntry {
    private:
        friend class BPA;
    public:
        FreeEntry() = default;
        FreeEntry(const uint32_t base)
        : base(base)
        {}

        uint32_t base;

        bool operator==(const FreeEntry& other) const { return (other.base == base); }
    };

    struct FreeArea {
        List<FreeEntry, OmaAllocator> free_list;
        Bitmap bitmap;

        using List_t = decltype(free_list);
    };

    static constexpr size_t max_areas = 13;

    static uint32_t allocated_pages;

    static FreeArea areas[max_areas];
    static Spinlock lock;

    static bool push_free_entry(const uint32_t base, const uint32_t size);
    static bool init_areas(uint8_t* bitmap_base, const uint32_t max_pages);

    static inline void clear_page_bit(const uint32_t base, const uint32_t rank) {
        areas[rank].bitmap.clear(base >> (1 + rank));
    }

    static inline void set_page_bit(const uint32_t base, const uint32_t rank) {
        areas[rank].bitmap.set(base >> (1 + rank));
    }

    static inline uint8_t get_page_bit(const uint32_t base, const uint32_t rank) {
        return areas[rank].bitmap.get(base >> (1 + rank));
    }

    static inline void inverse_page_bit(const uint32_t base, const uint32_t rank) {
        areas[rank].bitmap.inverse(base >> (1 + rank));
    }
public:
    static constexpr uintptr_t alloc_fail = Arch::invalid_phys;
public:
    static Status init();

    static uintptr_t alloc_pages(const unsigned rank);
    static void free_pages(const uintptr_t base, const unsigned rank);
};