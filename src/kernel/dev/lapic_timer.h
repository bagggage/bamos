#pragma once

#include "definitions.h"
#include "timer.h"

#define LAPIC_TIMER_INT_VECTOR 32

Status init_lapic_timer(TimerDevice* dev);

// Configure lapic timer for current cpu
void configure_lapic_timer();