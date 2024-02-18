#pragma once

#include "definitions.h"

// Common header for all devices
// For each unique device needs to define init_<device-name> function in <device-name>.h
//
// This function should return 'Status' and takes pointer to an device structure for current device type
// like 'KeyboardDevice', status might be 'KERNEL_OK' if device initialized successfully and device structure
// might be filled with device's data and interface
// otherwise if something went wrong, device structure doesn't change

// Common device structure
typedef struct Device {
// TODO: maybe id, name, type idk... something
} Device;

#define DEVICE_STRUCT_IMPL(dev_name) \
    Device common; \
    dev_name ## Interface interface