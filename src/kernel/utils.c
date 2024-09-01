#include "utils.h"

#include "dev/timer.h"

void wait(uint64_t delay_ms) {
    TimerDevice* timer = (TimerDevice*)dev_find_by_type(NULL, DEV_TIMER);

    if (timer == NULL) return;

    uint64_t begin_time_ms = (timer->interface.get_clock_counter(timer) * timer->min_clock_time) * PS_TO_MS;
    uint64_t curr_time_ms = begin_time_ms;

    do {
        curr_time_ms = (timer->interface.get_clock_counter(timer) * timer->min_clock_time) * PS_TO_MS;
    } while ((curr_time_ms - begin_time_ms) < delay_ms);
}