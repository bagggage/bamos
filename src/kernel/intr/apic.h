#pragma once

#include "definitions.h"
#include "dev/stds/acpi.h"

typedef enum MADTEntryType {
    MADT_ENTRY_TYPE_PROC_LAPIC,
    MADT_ENTRY_TYPE_IOAPIC,
    MADT_ENTRY_TYPE_IOAPIC_INT_SRC_OVERR,
    MADT_ENTRY_TYPE_IOAPIC_NONMASK_INT_SRC,
    MADT_ENTRY_TYPE_IOAPIC_NONMASK_INT,
    MADT_ENTRY_TYPE_LAPIC_ADDR_OVERR,
    MADT_ENTRY_TYPE_PROC_LX2APIC
} MADTEntryType;

typedef struct MADTEntry {
    uint8_t type;
    uint8_t length;
} ATTR_PACKED MADTEntry;

typedef struct MADT {
    ACPISDTHeader header;
    uint32_t lapic_address;
    uint32_t flags;
    MADTEntry entries;
} ATTR_PACKED MADT;

typedef struct ProcLocalAPIC {
    MADTEntry header;
    uint8_t acpi_proc_id;
    uint8_t apic_id;
    uint32_t flags;
} ATTR_PACKED ProcLocalAPIC;

typedef struct IOAPIC {
    MADTEntry header;
    uint8_t ioapic_id;
    uint8_t reserved;
    uint32_t ioapic_address;
    uint32_t global_sys_int_base;
} ATTR_PACKED IOAPIC;

typedef struct IOAPICIntSourceOverride {
    MADTEntry header;
    uint8_t bus_source;
    uint8_t irq_source;
    uint32_t global_sys_int;
    uint16_t flags;
} ATTR_PACKED IOAPICIntSourceOverride;

typedef struct IOAPICNonMaskIntSource {
    MADTEntry header;
    uint8_t nmi_source;
    uint8_t reserved;
    uint16_t flags;
    uint32_t global_sys_int;
} ATTR_PACKED IOAPICNonMaskIntSource;

typedef struct IOAPICNonMaskInt {
    MADTEntry header;
    uint8_t acpi_proc_id; // 0xFF means all processors
    uint16_t flags;
    uint8_t lint; // 0 or 1
} ATTR_PACKED IOAPICNonMaskInt;

typedef struct LocalAPICAddressOverride {
    MADTEntry header;
    uint16_t reserved;
    uint64_t lapic_address;
} ATTR_PACKED LocalAPICAddressOverride;

typedef struct ProcLocalX2APIC {
    MADTEntry header;
    uint16_t reserved;
    uint32_t proc_local_x2apic_id;
    uint32_t flags;
    uint32_t acpi_id;
} ATTR_PACKED ProcLocalX2APIC;

extern MADT* apic_madt;

MADTEntry* madt_find_fist_entry_of_type(MADTEntryType type);

bool_t is_apic_avail();

Status init_apic();