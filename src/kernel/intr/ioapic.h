#pragma once

#include "definitions.h"

#define IOREGSEL 0x00
#define IOREGWIN 0x10

#define IOAPICID_REG 0x0
#define IOAPICVER_REG 0x1
#define IOAPICARB_REG 0x2
#define IOREDTBL_REG 0x3

#define IOAPIC_IRQ_OFFSET 0x10
#define IOAPIC_IRQ_LENGTH 0x02

typedef enum IOAPICDeliveryMode {
    IOAPIC_DELV_MODE_NORMAL = 0,
    IOAPIC_DELV_MODE_LOW_PRIORITY = 1,
    IOAPIC_DELV_MODE_SYS_MANG_INT = 2,
} IOAPICDeliveryMode;

typedef enum IOAPICDestMode {
    IOAPIC_DEST_PHYSICAL = 0,
    IOAPIC_DEST_LOGICAL = 1
} IOAPICDestMode;

typedef enum IOAPICTriggerMode {
    IOAPIC_DELIVERY_EDGE = 0,
    IOAPIC_DELIVERY_LEVEL = 1
} IOAPICTriggerMode;

typedef union IOAPICRedirEntry {
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
} IOAPICRedirEntry;

static inline void ioapic_write32(const uintptr_t apic_base, const uint8_t offset, const uint32_t data) {
    *(volatile uint32_t*)(apic_base + IOREGSEL) = offset;
    *(volatile uint32_t*)(apic_base + IOREGWIN) = data; 
}

static inline uint32_t ioapic_read32(const uintptr_t apic_base, const uint8_t offset) {
    *(volatile uint32_t*)(apic_base + IOREGSEL) = offset;

    return *(volatile uint32_t*)(apic_base + IOREGWIN); 
}

static inline void ioapic_write64(const uintptr_t apic_base, const uint8_t offset, const uint64_t data) {
    ioapic_write32(apic_base, offset, (uint32_t)(data & 0xFFFFFFFF));
    ioapic_write32(apic_base, offset + sizeof(uint32_t), (uint32_t)(data >> 32));
}

static inline uint64_t ioapic_read64(const uintptr_t apic_base, const uint8_t offset) {
    uint32_t out_low = ioapic_read32(apic_base, offset);
    uint32_t out_high = ioapic_read32(apic_base, offset + sizeof(uint32_t));

    return (uint64_t)(((uint64_t)out_high << 32) + out_low);
}

bool_t is_ioapic_avail();

Status init_ioapic();