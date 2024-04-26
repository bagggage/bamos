#pragma once

#include "definitions.h"
#include "device.h"

// Time convertion constants
#define PS_TO_NS ((double)1.0e-3)
#define PS_TO_MS ((double)1.0e-9)
#define NS_TO_MS ((double)1.0e-6)

typedef struct TimerDevice TimerDevice;

DEV_FUNC(Timer, uint64_t, get_clock_counter, TimerDevice*);
DEV_FUNC(Timer, void, set_divider, TimerDevice*, const uint32_t);

// TODO
typedef struct TimerInterface {
    Timer_get_clock_counter_t get_clock_counter;
    Timer_set_divider_t set_divider;
} TimerInterface;

// TODO
typedef struct TimerDevice {
    DEVICE_STRUCT_IMPL(Timer);

    // Minimal clock time in picoseconds
    uint64_t min_clock_time;
} TimerDevice;
