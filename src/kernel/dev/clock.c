#include "clock.h"

#include "assert.h"

typedef enum TotalSeconds {
    SECONDS_PER_NON_LEAP_YEAR = 31536000,
    SECONDS_PER_LEAP_YEAR = 31622400,
    SECONDS_PER_DAY = 86400,
    SECONDS_PER_HOUR = 3600,
    SECONDS_PER_MINUTE = 60
} TotalSeconds;

static const uint16_t DAYS_PER_MONTH[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

static bool_t is_leap_year(uint16_t year) {
    return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
}

uint32_t get_current_posix_time(ClockDevice* const clock_device) {
    kassert(clock_device != NULL);

    clock_device->interface.get_current_time(clock_device);

    uint32_t posix_time = 0;

    for (uint16_t i = 1970; i < clock_device->date_and_time.year; ++i) {
        posix_time += is_leap_year(i) ? SECONDS_PER_LEAP_YEAR : SECONDS_PER_NON_LEAP_YEAR;
    }

    for (uint8_t i = 0; i < clock_device->date_and_time.month - 1; i++) {
        posix_time += DAYS_PER_MONTH[i] * SECONDS_PER_DAY;
        
        if (i == 1 && is_leap_year(clock_device->date_and_time.year)) {
            posix_time += SECONDS_PER_DAY;
        }
    }

    posix_time += (clock_device->date_and_time.day - 1) * SECONDS_PER_DAY;
    posix_time += (clock_device->date_and_time.hour) * SECONDS_PER_HOUR + 
                     (clock_device->date_and_time.minute) * SECONDS_PER_MINUTE + 
                     clock_device->date_and_time.second;

    return posix_time;
}