#include "hpet_timer.h"

#include "logger.h"

// Read-only
#define HPET_GEN_CAPB_AND_ID_REG    0x000
// Read/write
#define HPET_GEN_CONFIG_REG         0x008
// Read/write clear
#define HPET_GEN_INT_STATUS_REG     0x020
// Read/write
#define HPET_MAIN_COUNT_VAL_REG     0x0F0
// Read/write
#define HPET_T0_CONFIG_AND_CAPB_REG 0x100
// Read/write
#define HPET_T0_COMP_VAL_REG        0x108
// Read/write
#define HPET_T0_FSB_INTR_REG        0x110
// Read/write
#define HPET_T1_CONFIG_AND_CAPB_REG 0x120
// Read/write
#define HPET_T1_COMP_VAL_REG        0x128
// Read/write
#define HPET_T1_FSB_INTR_REG        0x130
// Read/write
#define HPET_T2_CONFIG_AND_CAPB_REG 0x140
// Read/write
#define HPET_T2_COMP_VAL_REG        0x148
// Read/write
#define HPET_T2_FSB_INTR_REG        0x150

typedef struct GeneralCapbAndIDReg {
    uint8_t revision;

    union {
        uint8_t num_tim_cap : 5;
        uint8_t count_size_cap : 1;
        uint8_t reserved : 1;
        uint8_t leg_route_cap : 1;
    };

    uint16_t vendor_id;
    uint32_t counter_clk_period;
} ATTR_PACKED GeneralCapbAndIDReg;

static HPET* hpet = NULL;

bool_t is_hpet_timer_avail() {
    return (hpet = (HPET*)acpi_find_entry("HPET")) != NULL;
}

Status init_hpet_timer() {
    if (hpet == NULL) { 
        hpet = (HPET*)acpi_find_entry("HPET");

        if (hpet == NULL) {
            error_str = "HPET timer not available";
            return KERNEL_ERROR;
        }
    }

    if (acpi_checksum((ACPISDTHeader*)hpet) == FALSE) {
        error_str = "HPET checksum failed";
        return KERNEL_ERROR;
    }

    kernel_msg("HPET Clock period: %u femptoseconds\n", hpet->minimum_tick);

    return KERNEL_OK;
}