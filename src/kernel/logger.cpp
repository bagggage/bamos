#include "logger.h"

Spinlock Logger::lock = Spinlock();
char Logger::buffer[] = {};

