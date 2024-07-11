#pragma once

#include "arch.h"
#include "definitions.h"
#include "oma.h"

#include "utils/list.h"

class Heap {
private:
    struct Range {
        uintptr_t base;
        uint32_t pages;

        inline uintptr_t top() const { return base + (pages * Arch::page_size); }
    };

    uintptr_t start;
    uintptr_t top;

    List<Range, OmaAllocator> free_ranges;

    using RangeNode = decltype(free_ranges)::Node;

    void remove_range(RangeNode* const node, const uint32_t pages);
public:
    Heap() = default;
    Heap(const uintptr_t base)
    : start(base) {}

    uintptr_t reserve(const uint32_t pages);
    void release(const uintptr_t base, const uint32_t pages);
};