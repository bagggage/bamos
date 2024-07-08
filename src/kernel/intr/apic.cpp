#include "lapic.h"

bool LAPIC::is_initialized = false;
uintptr_t LAPIC::base = 0;