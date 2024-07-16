#pragma once

#include "definitions.h"
#include "arch.h"
#include "oma.h"

#include "utils/list.h"

struct PhysPageFrame {
public:
    uint32_t base;
    uint16_t size;

    bool is_base;

public:
    PhysPageFrame(uint32_t base, uint16_t size, bool is_base = true)
    : base(base), size(size), is_base(is_base)
    {}

    PhysPageFrame(uintptr_t base, uint8_t rank)
    : base(base / Arch::page_size), size(1 << rank), is_base(true)
    {}

    inline uint32_t end() const { return base + size; }
};

struct PageFrame {
public:
    uintptr_t virt;
    SList<PhysPageFrame, OmaAllocator> phys_frames;

    uint32_t pages;
};

constexpr auto a = sizeof(PhysPageFrame);