#pragma once

#include "definitions.h"

typedef struct GAS {
    uint8_t address_space_id;    // 0 - system memory, 1 - system I/O
    uint8_t register_bit_width;
    uint8_t register_bit_offset;
    uint8_t reserved;
    uint64_t address;
} ATTR_PACKED GAS;

typedef struct ACPISDTHeader {
    char signature[4];
    uint32_t length;
    uint8_t revision;
    uint8_t checksum;
    char oemid[6];
    uint64_t oem_tableid;
    uint32_t oem_revision;
    uint32_t creator_id;
    uint32_t creator_revision;
} ATTR_PACKED ACPISTDHeader;

typedef struct RSDT {
    ACPISDTHeader header;
    uint32_t* other_sdt; // Size of pointers array [(header.length - sizeof(header)) / 4]
} RSDT;

typedef struct XSDT {
    ACPISDTHeader header;
    uint64_t* other_sdt; // Size of pointers array [(header.length - sizeof(header)) / 8]
} XSDT;

struct FADT
{
    ACPISDTHeader header;
    uint32_t firmware_ctrl;
    uint32_t dsdt;
 
    // field used in ACPI 1.0; no longer in use, for compatibility only
    uint8_t  reserved;
 
    uint8_t  preferred_power_management_profile;
    uint16_t sci_interrupt;
    uint32_t smi_command_port;
    uint8_t  acpi_enable;
    uint8_t  acpi_disable;
    uint8_t  s4bios_req;
    uint8_t  pstate_control;
    uint32_t pm1a_event_block;
    uint32_t pm1b_event_block;
    uint32_t pm1a_control_block;
    uint32_t pm1b_control_clock;
    uint32_t pm2_control_block;
    uint32_t pm_timer_block;
    uint32_t gpe0_block;
    uint32_t gpe1_block;
    uint8_t  pm1_event_length;
    uint8_t  pm1_control_length;
    uint8_t  pm2_control_length;
    uint8_t  pm_timer_length;
    uint8_t  gpe0_length;
    uint8_t  gpe1_length;
    uint8_t  gpe1_base;
    uint8_t  cstate_control;
    uint16_t worst_c2_latency;
    uint16_t worst_c3_latency;
    uint16_t flush_size;
    uint16_t flush_stride;
    uint8_t  duty_offset;
    uint8_t  duty_width;
    uint8_t  day_alarm;
    uint8_t  month_alarm;
    uint8_t  century;
 
    // reserved in ACPI 1.0; used since ACPI 2.0+
    uint16_t boot_arch_flags;
 
    uint8_t  reserved_2;
    uint32_t flags;
 
    // 12 byte structure; see below for details
    GAS reset_reg;
 
    uint8_t  reset_value;
    uint8_t  reserved_3[3];
 
    // 64bit pointers - Available on ACPI 2.0+
    uint64_t x_firmware_control;
    uint64_t x_dsdt;
 
    GAS x_pm1a_event_block;
    GAS x_pm1b_event_block;
    GAS x_pm1a_control_block;
    GAS x_pm1b_control_block;
    GAS x_pm2_control_block;
    GAS x_pm_timer_block;
    GAS x_gpe0_block;
    GAS x_gpe1_block;
};

