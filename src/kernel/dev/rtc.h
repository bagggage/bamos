#pragma once 

#include "dev/clock.h"
 
// the rtc clock should always store hours in utc+0
Status init_rtc(ClockDevice* const clock_device);