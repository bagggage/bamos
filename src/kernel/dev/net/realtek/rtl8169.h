#pragma once

#include "definitions.h"

#include "dev/network.h"

#include "dev/stds/pci.h"

/* This driver is compatible with the following Realtek devices:
    + ------------+------------ +
    |  Vendor ID  |  Device ID  |
    +-------------+------------ +
    |    10ec     |    8161     |
    |    10ec     |    8168     |
    |    10ec     |    8169     |
    |    1259     |    c107     |
    |    1737     |    1032     |
    |    16ec     |    0116     |
    +-------------+-------------+
*/

typedef struct Rtl8169Descriptor {
    uint32_t command;  // command/status
    uint32_t vlan;
    union {
        struct {
            uint32_t low_buffer;  // low 32-bits of physical buffer address
            uint32_t high_buffer; // high 32-bits of physical buffer address (Only for 64 bit OS, otherwise 0)
        };
        uint64_t buffer;
    };
} Rtl8169Descriptor;

typedef struct Rtl8169Device {
    NETWORK_DEVICE_STRUCT_IMPL;

    Rtl8169Descriptor* rx_descriptors;
    Rtl8169Descriptor* tx_descriptors;
} Rtl8169Device;

bool_t is_rtl8169_controller(const PciDevice* const pci_device);

Status init_rtl8169(const PciDevice* const pci_device);