#pragma once

#include "definitions.h"
#include "timer.h"

bool_t is_acpi_timer_avail();

Status init_acpi_timer(TimerDevice* dev);