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
    };

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
