#pragma once

#include "definitions.h"

#include "dev/timer.h"
#include "dev/stds/acpi.h"

typedef struct HPET {
    ACPISDTHeader header;
    uint8_t hardware_rev_id;
    uint8_t comparator_count : 5;
    uint8_t counter_size : 1;
    uint8_t reserved : 1;
    uint8_t legacy_replacement : 1;
    uint16_t pci_vendor_id;
    GAS address;
    uint8_t hpet_number;
    uint16_t minimum_tick;
    uint8_t page_protection;
} ATTR_PACKED HPET;

bool_t is_hpet_timer_avail();

Status init_hpet_timer();