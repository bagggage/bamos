#pragma once

#include "definitions.h"

enum LapicRegs {
    LAPIC_ID_REG                = 0x020,
    LAPIC_VER_REG               = 0x030,
    LAPIC_TPR_REG               = 0x080,
    LAPIC_APR_REG               = 0x090,
    LAPIC_PPR_REG               = 0x0A0,
    LAPIC_EOI_REG               = 0x0B0,
    LAPIC_RRD_REG               = 0x0C0,
    LAPIC_LOGICAL_DEST_REG      = 0x0D0,
    LAPIC_DEST_FORMAT_REG       = 0x0E0,
    LAPIC_SUPRIOR_INT_VEC_REG   = 0x0F0,
    LAPIC_ISR_REG_BASE          = 0x100,
    LAPIC_TRIGGER_MODE_REG      = 0x180,
    LAPIC_INT_REQUEST_REG       = 0x200,
    LAPIC_ERROR_STATUS_REG      = 0x280,
    LAPIC_LVT_CMCI_REG          = 0x2F0,
    LAPIC_INT_CMD_REG           = 0x300,
    LAPIC_LVT_TIMER_REG         = 0x320,
    LAPIC_LVT_THERM_SENSOR_REG  = 0x330,
    LAPIC_LVT_PERF_COUNTERS_REG = 0x340,
    LAPIC_LVT_LINT0_REG         = 0x350,
    LAPIC_LVT_LINT1_REG         = 0x360,
    LAPIC_LVT_ERROR_REG         = 0x370,
    LAPIC_INIT_COUNTER_REG      = 0x380,
    LAPIC_CURR_COUNTER_REG      = 0x390,
    LAPIC_DIVIDER_CONFIG_REG    = 0x3E0
};

class LAPIC {
private:
    static uintptr_t base;
    static bool is_initialized;
public:
    static inline bool is_avail() { return is_initialized; }

    static inline uint32_t read(const uint32_t reg) {
        return *reinterpret_cast<uint32_t*>(base + reg);
    }

    static inline void write(const uint32_t reg, const uint32_t value) {
        *reinterpret_cast<uint32_t*>(base + reg) = value;
    }

    static inline uint32_t get_id() {
        return read(LAPIC_ID_REG);
    }
};