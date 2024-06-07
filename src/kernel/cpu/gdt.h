#pragma once

#include "definitions.h"

#define KERNEL_PRIVILAGE_LEVEL 0
#define USER_PRIVILAGE_LEVEL 3

typedef struct SegmentAccessByte {
    uint8_t access : 1;
    uint8_t read_write : 1;
    uint8_t dc : 1;
    uint8_t exec : 1;
    uint8_t descriptor_type : 1;
    uint8_t privilage_level : 2;
    uint8_t present : 1;
} ATTR_PACKED SegmentAccessByte;

typedef struct SegmentDescriptor {
    uint16_t limit_1;
    uint16_t base_1;
    uint8_t base_2;
    uint8_t access_byte;

    struct {
        uint8_t limit_2 : 4;
        uint8_t flags : 4;
    } ATTR_PACKED;

    uint8_t base_3;
} ATTR_PACKED SegmentDescriptor;

typedef struct SegmentSelector {
    uint16_t rpl : 2;       // Requested privilege level
    uint16_t table_idx : 1; // GDT (0) or LDT (1)
    uint16_t segment_idx : 13;
} ATTR_PACKED SegmentSelector;

// Global descriptor table register
typedef struct GDTR64 {
    uint16_t size;
    uint64_t base;
} ATTR_PACKED GDTR64;

static inline GDTR64 cpu_get_current_gdtr() {
    GDTR64 gdtr_64;

    asm volatile("sgdt %0":"=memory"(gdtr_64));

    return gdtr_64;
}

static inline void cpu_set_gdt(const SegmentDescriptor* gdt, const uint32_t size) {
    GDTR64 gdtr_64;

    gdtr_64.base = (uint64_t)gdt;
    gdtr_64.size = size * sizeof(SegmentDescriptor);

    asm volatile("lgdt %0"::"memory"(gdtr_64));
}

static inline void cpu_set_gs(const uint16_t segment_idx, const bool_t is_local, const uint8_t privilage_level) {
    SegmentSelector gs;

    gs.segment_idx = segment_idx;
    gs.table_idx = is_local ? 1 : 0;
    gs.rpl = privilage_level;

    asm volatile("mov %0,%%gs"::"a"(gs));
}

static inline void cpu_set_cs(const uint16_t segment_idx, const bool_t is_local, const uint8_t privilage_level) {
    SegmentSelector cs;

    cs.segment_idx = segment_idx;
    cs.table_idx = is_local ? 1 : 0;
    cs.rpl = privilage_level;

    asm volatile("mov %0,%%cs"::"a"(cs));
}

static inline void cpu_set_ds(const uint16_t segment_idx, const bool_t is_local, const uint8_t privilage_level) {
    SegmentSelector ds;

    ds.segment_idx = segment_idx;
    ds.table_idx = is_local ? 1 : 0;
    ds.rpl = privilage_level;

    asm volatile("mov %0,%%ds"::"a"(ds));
}
