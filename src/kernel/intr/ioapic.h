#pragma once

#include "definitions.h"

#define IOREGSEL 0x00
#define IOREGWIN 0x10

#define IOAPIC_ID_REG 0x00
#define IOAPIC_VER_REG 0x01
#define IOAPIC_ARB_REG 0x02
#define IORED_TBL_REG 0x03

#define IOAPIC_REDTBL_OFFSET 0x10
#define IOAPIC_REDIR_ENTRY_LENGTH 0x02

typedef union IRQRedirectionEntry {
    struct {
        uint64_t vector         : 8;
        uint64_t delvery_mode   : 3;
        uint64_t dest_mode      : 1;
        uint64_t delvery_status : 1;
        uint64_t pin_polarity   : 1;
        uint64_t remote_irr     : 1;
        uint64_t trigger_mode   : 1;
        uint64_t mask           : 1;
        uint64_t reserved       : 39;
        uint64_t destination    : 8;
    };
    struct {
        uint32_t low_half;
        uint32_t high_half;
    };
} ATTR_PACKED IRQRedirectionEntry;

extern uint64_t ioapic_base;

static inline void ioapic_write32(const uintptr_t ioapic_base, const uint8_t offset, const uint32_t data) {
    *(volatile uint32_t*)(ioapic_base + IOREGSEL) = offset;
    *(volatile uint32_t*)(ioapic_base + IOREGWIN) = data; 
}

static inline uint32_t ioapic_read32(const uintptr_t ioapic_base, const uint8_t offset) {
    *(volatile uint32_t*)(ioapic_base + IOREGSEL) = offset;

    return *(volatile uint32_t*)(ioapic_base + IOREGWIN); 
}

static inline void ioapic_write64(const uintptr_t ioapic_base, const uint8_t offset, const uint64_t data) {
    ioapic_write32(ioapic_base, offset, (uint32_t)(data & 0xFFFFFFFF));
    ioapic_write32(ioapic_base, offset + sizeof(uint32_t), (uint32_t)(data >> 32));
}

static inline uint64_t ioapic_read64(const uintptr_t ioapic_base, const uint8_t offset) {
    uint32_t out_low = ioapic_read32(ioapic_base, offset);
    uint32_t out_high = ioapic_read32(ioapic_base, offset + sizeof(uint32_t));

    return (uint64_t)(((uint64_t)out_high << 32) + out_low);
}

void ioapic_mask_irq(const uint8_t irq_idx, const bool_t is_masked);

bool_t is_ioapic_avail();

Status init_ioapic();