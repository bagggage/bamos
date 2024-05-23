#pragma once

#include "definitions.h"

#include "dev/stds/pci.h"

typedef struct UdevFs {
    PciBus* pci_bus;
} UdevFs;

Status udev_init();