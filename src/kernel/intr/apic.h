#pragma once

#include "definitions.h"
#include "dev/stds/acpi.h"

#define LAPIC_ID_REG                0x020
#define LAPIC_VER_REG               0x030
#define LAPIC_TPR_REG               0x080
#define LAPIC_APR_REG               0x090
#define LAPIC_PPR_REG               0x0A0
#define LAPIC_EOI_REG               0x0B0
#define LAPIC_RRD_REG               0x0C0
#define LAPIC_LOGICAL_DEST_REG      0x0D0
#define LAPIC_DEST_FORMAT_REG       0x0E0
#define LAPIC_SUPRIOR_INT_VEC_REG   0x0F0
#define LAPIC_ISR_REG_BASE          0x100
#define LAPIC_TRIGGER_MODE_REG      0x180
#define LAPIC_INT_REQUEST_REG       0x200
#define LAPIC_ERROR_STATUS_REG      0x280
#define LAPIC_LVT_CMCI_REG          0x2F0
#define LAPIC_INT_CMD_REG           0x300
#define LAPIC_LVT_TIMER_REG         0x320
#define LAPIC_LVT_THERM_SENSOR_REG  0x330
#define LAPIC_LVT_PERF_COUNTERS_REG 0x340
#define LAPIC_LVT_LINT0_REG         0x350
#define LAPIC_LVT_LINT1_REG         0x360
#define LAPIC_LVT_ERROR_REG         0x370
#define LAPIC_INIT_COUNTER_REG      0x380
#define LAPIC_CURR_COUNTER_REG      0x390
#define LAPIC_DIVIDER_CONFIG_REG    0x3E0

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

typedef enum APICDeliveryMode {
    APIC_DELV_MODE_NORMAL = 0,
    APIC_DELV_MODE_LOW_PRIORITY = 1,
    APIC_DELV_MODE_SYS_MANG_INT = 2,
    APIC_DELV_MODE_NMI = 4,
    APIC_DELV_MODE_INIT = 5,
    APIC_DELV_MODE_SIPI = 6,
    APIC_DELV_MODE_EXTERNAL = 7,
} APICDeliveryMode;

typedef enum APICDestMode {
    APIC_DEST_PHYSICAL = 0,
    APIC_DEST_LOGICAL = 1
} APICDestMode;

typedef enum APICTriggerMode {
    APIC_DELIVERY_EDGE = 0,
    APIC_DELIVERY_LEVEL = 1
} APICTriggerMode;

typedef enum APICDestType {
    APIC_DEST_TYPE_IDX = 0,
    APIC_DEST_TYPE_CURR_CPU = 1,
    APIC_DEST_TYPE_ALL_CPUS = 2,
    APIC_DEST_TYPE_OTHER_CPUS = 3
} APICDestType;

typedef enum APICPolarity {
    APIC_POLARITY_HIGH_LEVEL = 0,
    APIC_POLARITY_LOW_LEVEL = 1
} APICPolarity;

typedef enum APICTimerMode {
    APIC_TIMER_MODE_ONE_SHOT = 0,
    APIC_TIMER_MODE_PERIODIC = 1
} APICTimerMode;

typedef struct LVTInterruptReg {
    uint32_t vector             : 8;
    uint32_t delivery_mode      : 3;
    uint32_t reserved0          : 1;
    uint32_t delivery_status    : 1;
    uint32_t pin_polarity       : 1;
    uint32_t remote_irr         : 1;
    uint32_t trigger_mode       : 1;
    uint32_t mask               : 1;
    uint32_t reserved1          : 15;
} ATTR_PACKED LVTInterruptReg;

typedef union LVTTimerReg {
    struct {
        uint32_t vector             : 8;
        uint32_t reserved0          : 4;
        uint32_t delivery_status    : 1;
        uint32_t reserved1          : 3;
        uint32_t mask               : 1;
        uint32_t timer_mode         : 1;
        uint32_t reserved2          : 14;
    };
    uint32_t value;
} ATTR_PACKED LVTTimerReg;

uint32_t lapic_read(const uint32_t reg);
void lapic_write(const uint32_t reg, const uint32_t value);

/*
Returns current cpu index.
*/
uint32_t lapic_get_cpu_idx();

MADTEntry* madt_find_first_entry_of_type(const MADTEntryType type);
MADTEntry* madt_next_entry_of_type(MADTEntry* begin, const MADTEntryType type);

bool_t is_apic_avail();

Status init_apic();