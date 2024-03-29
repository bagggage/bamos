#pragma once

#include "definitions.h"
#include "device.h"

// Time convertion constants
#define PS_TO_NS (1.0e-3)
#define PS_TO_MS (1.0e-9)
#define NS_TO_MS (1.0e-6)

typedef struct TimerDevice TimerDevice;

DEV_FUNC(Timer, uint64_t, get_clock_counter, TimerDevice*);

// TODO
typedef struct TimerInterface {
    Timer_get_clock_counter_t get_clock_counter;
} TimerInterface;

// TODO
typedef struct TimerDevice {
    DEVICE_STRUCT_IMPL(Timer);

    // Minimal clock time in picoseconds
    uint64_t min_clock_time; 
} TimerDevice;
