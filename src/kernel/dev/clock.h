#pragma once 

#include "definitions.h"
#include "device.h"

// Hours should always be in utc+0
typedef struct DateTime {
    uint8_t second;
    uint8_t minute;
    uint8_t hour;
    uint8_t day;
    uint8_t month;
    uint16_t year;
    char day_of_week[4];
    char month_str[10];
} DateTime;

typedef struct ClockDevice ClockDevice;

DEV_FUNC(Clock, void, get_current_time, ClockDevice* const clock_device);
DEV_FUNC(Clock, void, set_current_time, const DateTime* const date_time);

typedef struct ClockInterface {
    Clock_get_current_time_t get_current_time;
    Clock_set_current_time_t set_current_time;
} ClockInterface;

typedef struct ClockDevice {
    DEVICE_STRUCT_IMPL(Clock);

    DateTime date_and_time;
} ClockDevice;

uint32_t get_current_posix_time(ClockDevice* const clock_device);