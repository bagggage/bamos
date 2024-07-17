#pragma once

#include "definitions.h"

#include "bpa.h"
#include "oma.h"
#include "frame.h"

#include "utils/binary-tree.h"
#include "utils/math.h"

/*
Universal memory allocator
*/
class UMA {
private:
    static constexpr auto min_size = 16u;
    static constexpr auto min_rank = log2(min_size);
    static constexpr auto max_small_size = Arch::page_size / 2;
    static constexpr auto max_small_rank = log2(max_small_size) - min_rank + 1;

    static constexpr auto max_alloc_size = BPA::max_alloc_pages * Arch::page_size;

    static size_t allocated_bytes;

    using Tree_t = BinaryTree<PhysPageFrame, decltype(PhysPageFrame::base), &PhysPageFrame::base, OmaAllocator>;

    static OMA oma_pool[max_small_rank];
    static Tree_t large_allocs;
public:
    static Status init();

    static void* alloc(const uint32_t size);
    static void free(void* const ptr);
};